#!/usr/bin/env python3
"""Boot a disposable native VM; never run privileged PVE on the build host."""
import argparse
import fcntl
import hashlib
import json
import os
import platform
from pathlib import Path
import shlex
import shutil
import socket
import subprocess
import tempfile
import time
import uuid


def run(command, **kwargs):
    return subprocess.run(command, check=True, timeout=kwargs.pop('timeout',600),**kwargs)


def monitor_installation(ssh, command):
    """Report slow ARM TCG work without hiding a failed or stalled install."""
    process=subprocess.Popen(ssh+[command])
    deadline=time.monotonic()+1800
    try:
        while True:
            try:
                code=process.wait(timeout=min(60,max(1,deadline-time.monotonic())))
                if code:raise subprocess.CalledProcessError(code,ssh+[command])
                return
            except subprocess.TimeoutExpired:
                if time.monotonic()>=deadline:
                    raise TimeoutError('Disposable VM Docker installation exceeded 30 minutes')
                print('Disposable ARM VM installation progress:',flush=True)
                try:
                    subprocess.run(ssh+['ps -eo comm,pcpu,etime,wchan:24 --sort=-pcpu | head -15; free -m'],timeout=45,check=False)
                except subprocess.TimeoutExpired:
                    print('Disposable ARM VM progress probe timed out; installation deadline retained',flush=True)
    finally:
        if process.poll() is None:
            process.terminate()
            try:process.wait(timeout=10)
            except subprocess.TimeoutExpired:process.kill();process.wait(timeout=10)


def kvm_available():
    try:
        with open('/dev/kvm','rb') as device:
            descriptor=fcntl.ioctl(device,0xAE01,0)
            os.close(descriptor)
        return True
    except OSError:
        return False


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('major',choices=['7','8','9']);parser.add_argument('image')
    args=parser.parse_args()
    arch={'x86_64':'amd64','aarch64':'arm64'}.get(platform.machine())
    if arch is None:raise RuntimeError('Unsupported native verification architecture')
    if not Path('/.dockerenv').is_file():raise RuntimeError('Use the isolated VM launcher image')
    for path in ['/input/image.tar','/input/guest.qcow2']:
        if not Path(path).is_file():raise RuntimeError('Missing read-only verification input')
    with tempfile.TemporaryDirectory(prefix='pve-docker-vm-') as temporary:
        folder=Path(temporary)
        filename=f'noble-server-cloudimg-{arch}.img'
        base='https://cloud-images.ubuntu.com/noble/current/'
        for name in [filename,'SHA256SUMS']:
            cached=Path('/input')/name
            if cached.is_file():
                shutil.copyfile(cached,folder/name)
            else:
                run(['curl','-fLsS','--retry','3','--connect-timeout','20','--max-time','1200',base+name,'-o',str(folder/name)],timeout=1500)
        hashes=[line.split()[0] for line in (folder/'SHA256SUMS').read_text().splitlines()
                if len(line.split())==2 and line.split()[1].lstrip('*./')==filename]
        with (folder/filename).open('rb') as handle:actual=hashlib.file_digest(handle,'sha256').hexdigest()
        if hashes!=[actual]:raise RuntimeError('Ubuntu VM checksum mismatch')
        run(['qemu-img','create','-f','qcow2','-F','qcow2','-b',str(folder/filename),str(folder/'disk.qcow2'),'48G'])
        key=folder/'client-key';host_key=folder/'host-key'
        for path in [key,host_key]:run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(path)])
        with socket.socket() as listener:
            listener.bind(('127.0.0.1',0));port=listener.getsockname()[1]
        known_hosts=folder/'known_hosts'
        known_hosts.write_text(f'[127.0.0.1]:{port} '+host_key.with_suffix('.pub').read_text())
        config={'disable_root':False,'ssh_pwauth':False,
                'users':[{'name':'root','ssh_authorized_keys':[key.with_suffix('.pub').read_text().strip()]}],
                'ssh_keys':{'ed25519_private':host_key.read_text(),'ed25519_public':host_key.with_suffix('.pub').read_text().strip()},
                'bootcmd':[['touch','/run/cnb-disposable-build']]}
        (folder/'user-data').write_text('#cloud-config\n'+json.dumps(config))
        (folder/'meta-data').write_text('instance-id: pve-docker-'+uuid.uuid4().hex+'\nlocal-hostname: pve-docker-validator\n')
        run(['cloud-localds',str(folder/'seed.img'),str(folder/'user-data'),str(folder/'meta-data')])
        options=['-i',str(key),'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',
                 '-o','UserKnownHostsFile='+str(known_hosts),'-o','ConnectTimeout=10',
                 '-o','ServerAliveInterval=30','-o','ServerAliveCountMax=4']
        ssh=['ssh','-p',str(port)]+options+['root@127.0.0.1']
        scp=['scp','-P',str(port)]+options
        accelerated=kvm_available()
        print('Disposable verification VM acceleration='+('kvm' if accelerated else 'tcg'),flush=True)
        # Only the outer disposable VM uses KVM. The PVE-managed guest still
        # uses TCG, so the same VM boot/reboot assertions run in either mode.
        # Keep the TCG CPU at x86-64-v2 to avoid wide-vector emulation costs.
        qemu=['qemu-system-x86_64','-machine','q35','-accel','kvm' if accelerated else 'tcg,thread=multi',
              '-cpu','host' if accelerated else 'Nehalem','-m','4096' if accelerated else '6144','-smp','2' if accelerated else '4',
              '-display','none','-serial','stdio','-no-reboot',
              '-drive',f'file={folder}/disk.qcow2,if=virtio,format=qcow2',
              '-drive',f'file={folder}/seed.img,if=virtio,format=raw,readonly=on',
              '-netdev',f'user,id=net0,hostfwd=tcp:127.0.0.1:{port}-:22','-device','virtio-net-pci,netdev=net0',
              '-object','rng-random,id=rng0,filename=/dev/urandom','-device','virtio-rng-pci,rng=rng0']
        if arch=='arm64':
            shutil.copyfile('/usr/share/AAVMF/AAVMF_VARS.fd',folder/'uefi-vars.fd')
            qemu[:7]=['qemu-system-aarch64','-machine','virt,gic-version=3',
                      '-accel','kvm' if accelerated else 'tcg,thread=multi',
                      # Avoid emulating SVE and other optional CPU features in
                      # the software-only verifier. ARMv8 is sufficient here.
                      '-cpu','host' if accelerated else 'cortex-a72']
            qemu.extend(['-drive','if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.fd',
                         '-drive',f'if=pflash,format=raw,file={folder}/uefi-vars.fd'])
        process=None
        with (folder/'serial.log').open('wb') as serial:
            try:
                process=subprocess.Popen(qemu,stdout=serial,stderr=subprocess.STDOUT)
                deadline=time.monotonic()+1200
                reported=time.monotonic()
                while time.monotonic()<deadline:
                    if process.poll() is not None:raise RuntimeError('Verification VM stopped before SSH')
                    try:
                        result=subprocess.run(ssh+['test -f /run/cnb-disposable-build'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=20)
                        if result.returncode==0:break
                    except subprocess.TimeoutExpired:
                        # Under TCG, SSH can accept TCP before it can finish a
                        # handshake. Keep the overall boot deadline and pinned
                        # host-key check; a single slow probe is not a boot failure.
                        pass
                    if time.monotonic()-reported>=60:
                        print('Waiting for disposable '+arch+' VM:\n'+(folder/'serial.log').read_text(errors='replace')[-1500:],flush=True)
                        reported=time.monotonic()
                    time.sleep(5)
                else:raise TimeoutError('Verification VM did not boot')
                print('PVE verification VM ready; SSH host key verified',flush=True)
                run(ssh+['cloud-init status --wait'],timeout=600)
                installation='export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y --no-install-recommends docker.io && modprobe -a fuse tun && test -c /dev/fuse && test -c /dev/net/tun'
                if arch=='arm64':
                    installation=installation.replace('apt-get ', 'apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 -o Acquire::Languages=none ')
                    monitor_installation(ssh,installation)
                else:
                    run(ssh+[installation],timeout=1800)
                run(scp+['/input/image.tar','/input/guest.qcow2','/checks/pve_container_runtime.py','root@127.0.0.1:/tmp/'],timeout=1800)
                run(ssh+['docker load -i /tmp/image.tar'],timeout=600)
                command='python3 /tmp/pve_container_runtime.py '+shlex.quote(args.image)+' '+args.major+' /tmp/guest.qcow2'
                run(ssh+[command],timeout=5400)
                subprocess.run(ssh+['poweroff'],timeout=30,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                process.wait(timeout=180)
                print('PVE_DOCKER_ISOLATED_VERIFICATION_COMPLETE major='+args.major+' architecture='+arch,flush=True)
            except BaseException:
                print((folder/'serial.log').read_text(errors='replace')[-5000:],flush=True)
                raise
            finally:
                if process is not None and process.poll() is None:
                    process.terminate()
                    try:process.wait(timeout=20)
                    except subprocess.TimeoutExpired:process.kill();process.wait(timeout=10)


if __name__=='__main__':main()
