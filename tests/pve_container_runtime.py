#!/usr/bin/env python3
"""Check a PVE Docker image only inside a disposable whole-system VM."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import time


def run(args, **kwargs):
    return subprocess.run(args, check=True, timeout=kwargs.pop('timeout', 180), **kwargs)


def output(args, **kwargs):
    return subprocess.check_output(args, text=True, timeout=kwargs.pop('timeout', 120), **kwargs).strip()


API_CHECK = '''import json,ssl,urllib.parse,urllib.request
from pathlib import Path
import socket,sys
host=socket.gethostname()
base='https://'+host+':8006/api2/json'
context=ssl.create_default_context(cafile='/etc/pve/pve-root-ca.pem')
body=urllib.parse.urlencode({'username':'root@pam','password':sys.stdin.read().strip()}).encode()
with urllib.request.urlopen(urllib.request.Request(base+'/access/ticket',data=body),context=context,timeout=10) as r:
    ticket=json.load(r)['data']['ticket']
request=urllib.request.Request(base+'/nodes/'+host+'/status',headers={'Cookie':'PVEAuthCookie='+ticket})
with urllib.request.urlopen(request,context=context,timeout=10) as r:
    assert json.load(r)['data']['uptime'] >= 0
print('PAM_API_LOGIN_OK')
'''

GUEST_CONSOLE = '''import socket
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
s.settimeout(10)
s.connect('/var/run/qemu-server/900001.serial0')
while True:
    try:
        data=s.recv(65536)
    except TimeoutError:
        continue
    if not data:break
    print(data.decode(errors='replace'),end='',flush=True)
'''


def main():
    p=argparse.ArgumentParser()
    p.add_argument('image'); p.add_argument('major',choices=['8','9']); p.add_argument('guest',type=Path)
    args=p.parse_args()
    if not Path('/run/cnb-disposable-build').is_file():
        raise RuntimeError('Run this privileged test inside the disposable verification VM')
    run(['systemd-detect-virt','--vm'],stdout=subprocess.DEVNULL)
    name='pve-docker-check-'+args.major
    vmid='900001'
    def dex(*command, **kwargs):
        return run(['docker','exec',name,*command],**kwargs)
    def dout(*command, **kwargs):
        return output(['docker','exec',name,*command],**kwargs)
    def wait_api(password):
        services=['pve-cluster','pvedaemon','pveproxy','pvestatd','ssh']
        deadline=time.monotonic()+900
        while time.monotonic()<deadline:
            # A proxy worker can accept requests before systemd finishes the
            # unit's startup hooks. Wait for every required service as well.
            state=subprocess.run(['docker','exec',name,'systemctl','is-active',*services],
                                 stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,timeout=30)
            if state.stdout.split()!=['active']*len(services):
                time.sleep(10)
                continue
            result=subprocess.run(['docker','exec','-i',name,'python3','-c',API_CHECK],input=password,text=True,
                                  stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=20)
            if result.returncode==0 and result.stdout.strip()=='PAM_API_LOGIN_OK':return
            time.sleep(10)
        raise RuntimeError('PVE authenticated HTTPS API did not become ready')
    def wait_guest(previous=None):
        deadline=time.monotonic()+1800
        while time.monotonic()<deadline:
            result=subprocess.run(['docker','exec',name,'qm','guest','exec',vmid,'--timeout','30','--',
                                   '/bin/sh','-c','test -r /etc/alpine-release && cat /proc/sys/kernel/random/boot_id'],
                                  stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,timeout=50)
            if result.returncode==0:
                value=json.loads(result.stdout)
                boot=value.get('out-data','').strip()
                if value.get('exited') and value.get('exitcode')==0 and len(boot)==36 and boot!=previous:return boot
            time.sleep(5)
        raise RuntimeError('Nested qm guest did not boot or reboot')
    with tempfile.TemporaryDirectory(prefix='pve-auth-') as folder:
        secret=Path(folder)/'root-password';password=secrets.token_urlsafe(24)
        secret.write_text(password);secret.chmod(0o600)
        console_path=Path(folder)/'guest-console.log'
        console=None
        try:
            run(['docker','run','-d','--name',name,'--hostname',name,'--privileged','--cgroupns=private',
                 '--tmpfs','/run','--tmpfs','/run/lock','--tmpfs','/tmp',
                 '--mount',f'type=bind,src={secret},dst=/run/secrets/pve-root,readonly',
                 '-e','PVE_ROOT_PASSWORD_FILE=/run/secrets/pve-root',args.image],stdout=subprocess.DEVNULL)
            wait_api(password)
            print('PVE authenticated HTTPS/PAM API ready',flush=True)
            dex('curl','--fail','--silent','--show-error','--cacert','/etc/pve/pve-root-ca.pem',
                'https://'+name+':8006/',stdout=subprocess.DEVNULL)
            for service in ['pve-cluster','pvedaemon','pveproxy','pvestatd','ssh']:
                dex('systemctl','is-active','--quiet',service)
            for service in ['systemd-binfmt','systemd-udevd','systemd-sysctl','systemd-modules-load',
                            'watchdog-mux','pve-ha-lrm','pve-ha-crm']:
                assert dout('systemctl','show','-p','LoadState','--value',service+'.service')=='masked'
            version=dout('dpkg-query','-W','-f=${Version}','pve-manager')
            assert version.startswith(args.major+'.')
            ca=dout('sha256sum','/etc/pve/pve-root-ca.pem').split()[0]
            storages=json.loads(dout('pvesh','get','/storage','--output-format','json'))
            if any(x['storage']=='local' for x in storages):
                dex('pvesm','set','local','--content','images,rootdir,vztmpl,iso,backup')
            else:
                dex('pvesm','add','dir','local','--path','/var/lib/vz','--content','images,rootdir,vztmpl,iso,backup')
            dex('ip','link','add','vmbr0','type','bridge')
            dex('ip','addr','add','10.76.0.1/24','dev','vmbr0')
            dex('ip','link','set','vmbr0','up')
            guest_path='/var/lib/vz/template/iso/runtime-guest.qcow2'
            dex('mkdir','-p','/var/lib/vz/template/iso')
            run(['docker','cp',str(args.guest),name+':'+guest_path])
            dex('qm','create',vmid,'--name','docker-smoke','--memory','1024','--cores','2','--kvm','0',
                '--cpu','x86-64-v2-AES','--machine','q35','--bios','ovmf',
                '--efidisk0','local:1,efitype=4m,pre-enrolled-keys=0','--agent','enabled=1',
                '--rng0','source=/dev/urandom',
                '--net0','virtio,bridge=vmbr0','--serial0','socket','--vga','serial0')
            dex('qm','importdisk',vmid,guest_path,'local','--format','qcow2')
            config=dout('qm','config',vmid)
            volume=next(line.split(': ',1)[1] for line in config.splitlines() if line.startswith('unused0: '))
            dex('qm','set',vmid,'--virtio0',volume,'--boot','order=virtio0','--ide2','local:cloudinit',
                '--ipconfig0','ip=10.76.0.2/24,gw=10.76.0.1','--nameserver','1.1.1.1')
            dex('qm','start',vmid)
            with console_path.open('wb') as log:
                console=subprocess.Popen(['docker','exec',name,'python3','-u','-c',GUEST_CONSOLE],
                                         stdout=log,stderr=subprocess.STDOUT)
            print('PVE test VM started; waiting for the guest agent',flush=True)
            boot=wait_guest()
            print('PVE test VM reached the Alpine guest agent; requesting reboot',flush=True)
            dex('qm','reboot',vmid,'--timeout','120')
            wait_guest(boot)
            print('PVE test VM boot and reboot verified',flush=True)
            dex('qm','stop',vmid)
            changed=secrets.token_urlsafe(24)
            run(['docker','exec','-i',name,'chpasswd'],input='root:'+changed+'\n',text=True)
            run(['docker','restart',name],stdout=subprocess.DEVNULL)
            wait_api(changed)
            assert ca==dout('sha256sum','/etc/pve/pve-root-ca.pem').split()[0]
            assert 'name: docker-smoke' in dout('qm','config',vmid)
            dex('qm','destroy',vmid,'--purge','1')
            print('PVE_DOCKER_RUNTIME_OK '+json.dumps({'major':args.major,'version':version,
                  'https_pam':True,'qm_boot_reboot':'tcg','container_restart':True,
                  'password_change_persistent':True,'host_units_masked':True}),flush=True)
        except BaseException:
            if console_path.is_file():
                print('PVE test guest console (last 6000 characters):',flush=True)
                print(console_path.read_text(errors='replace')[-6000:],flush=True)
            subprocess.run(['docker','logs','--tail','100',name],check=False)
            subprocess.run(['docker','exec',name,'systemctl','--failed','--no-pager'],check=False)
            subprocess.run(['docker','exec',name,'systemctl','show','pve-cluster','pvedaemon','pveproxy',
                            '-p','ActiveState','-p','SubState','-p','Result'],check=False)
            subprocess.run(['docker','exec',name,'journalctl','--no-pager','-n','80',
                            '-u','pve-cluster','-u','pvedaemon','-u','pveproxy'],check=False)
            raise
        finally:
            if console is not None and console.poll() is None:
                console.terminate()
                try:console.wait(timeout=10)
                except subprocess.TimeoutExpired:console.kill();console.wait(timeout=10)
            subprocess.run(['docker','rm','-f',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)


if __name__=='__main__':main()
