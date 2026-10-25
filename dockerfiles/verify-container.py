#!/usr/bin/env python3
"""Boot a disposable amd64 VM; never run privileged PVE on the build host."""
import argparse
import hashlib
import json
import os
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


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('major',choices=['8','9']);parser.add_argument('image')
    args=parser.parse_args()
    if not Path('/.dockerenv').is_file():raise RuntimeError('Use the isolated VM launcher image')
    for path in ['/input/image.tar','/input/guest.qcow2']:
        if not Path(path).is_file():raise RuntimeError('Missing read-only verification input')
    with tempfile.TemporaryDirectory(prefix='pve-docker-vm-') as temporary:
        folder=Path(temporary)
        filename='noble-server-cloudimg-amd64.img'
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
        qemu=['qemu-system-x86_64','-machine','q35','-accel','tcg,thread=multi','-cpu','max','-m','6144','-smp','4',
              '-display','none','-serial','stdio','-no-reboot',
              '-drive',f'file={folder}/disk.qcow2,if=virtio,format=qcow2',
              '-drive',f'file={folder}/seed.img,if=virtio,format=raw,readonly=on',
              '-netdev',f'user,id=net0,hostfwd=tcp:127.0.0.1:{port}-:22','-device','virtio-net-pci,netdev=net0',
              '-object','rng-random,id=rng0,filename=/dev/urandom','-device','virtio-rng-pci,rng=rng0']
        process=None
        with (folder/'serial.log').open('wb') as serial:
            try:
                process=subprocess.Popen(qemu,stdout=serial,stderr=subprocess.STDOUT)
                deadline=time.monotonic()+1200
                while time.monotonic()<deadline:
                    if process.poll() is not None:raise RuntimeError('Verification VM stopped before SSH')
                    result=subprocess.run(ssh+['test -f /run/cnb-disposable-build'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=20)
                    if result.returncode==0:break
                    time.sleep(5)
                else:raise TimeoutError('Verification VM did not boot')
                print('PVE verification VM ready; SSH host key verified',flush=True)
                run(ssh+['cloud-init status --wait'],timeout=600)
                run(ssh+['export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y --no-install-recommends docker.io && modprobe -a fuse tun && test -c /dev/fuse && test -c /dev/net/tun'],timeout=1800)
                run(scp+['/input/image.tar','/input/guest.qcow2','/checks/pve_container_runtime.py','root@127.0.0.1:/tmp/'],timeout=1800)
                run(ssh+['docker load -i /tmp/image.tar'],timeout=600)
                command='python3 /tmp/pve_container_runtime.py '+shlex.quote(args.image)+' '+args.major+' /tmp/guest.qcow2'
                run(ssh+[command],timeout=3600)
                subprocess.run(ssh+['poweroff'],timeout=30,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                process.wait(timeout=180)
                print('PVE_DOCKER_ISOLATED_VERIFICATION_COMPLETE major='+args.major,flush=True)
            except BaseException:
                print((folder/'serial.log').read_text(errors='replace')[-5000:],flush=True)
                raise
            finally:
                if process is not None and process.poll() is None:
                    process.terminate()
                    try:process.wait(timeout=20)
                    except subprocess.TimeoutExpired:process.kill();process.wait(timeout=10)


if __name__=='__main__':main()
