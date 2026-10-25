#!/usr/bin/env python3
"""Trusted execution transport. User argv ONLY runs in a guest, never on the host.
Docker is an explicit development/test provider, not microVM admission evidence.
"""
import json
import base64
import os
import shlex
import subprocess
import sys
import tempfile
import time
import threading
from pathlib import Path
from workspace import unpack, pack, MAX_BYTES

MAX_LOG=1024*1024
ROOT=Path(__file__).resolve().parent

def shell(argv):
    return shlex.join(argv)

def docker(*args, check=True, timeout=180):
    result=subprocess.run(['docker',*args],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
    if check and result.returncode:
        raise RuntimeError('Docker command failed')
    return result

class Docker:
    def __init__(self,p):
        self.p=p
        self.name='ep-'+p['reservation']['creation_key']
    def create(self):
        r=self.p['reservation']
        # No bind mounts, Docker socket, host networking or capabilities.
        docker('run','-d','--name',self.name,'--network','none','--cap-drop','ALL','--cap-add','CHOWN','--cap-add','FOWNER','--cap-add','DAC_OVERRIDE','--cap-add','SETUID','--cap-add','SETGID','--cap-add','KILL',
               '--security-opt','no-new-privileges','--pids-limit','128','--memory',str(r['memory_mib'])+'m',
               '--cpus',str(r['vcpus']), '--label','execution-pool.creation='+r['creation_key'],
               self.p['template']['image_digest'],'sleep','14400')
        self.cmd("mkdir -p /opt/execution-pool /run/task /run/secrets /workspace /tmp/pool-scratch; chmod 1777 /tmp/pool-scratch",root=True)
        for name in ['workspace.py','guest.py']:
            docker('cp',str(ROOT/name),self.name+':/opt/execution-pool/'+name)
        return self.name
    def cmd(self,command,root=False,timeout=180):
        return docker('exec','--user','0' if root else '1000','--workdir','/',self.name,
                      'sh','-c','export HOME='+('/root' if root else '/tmp/pool-scratch')+'; '+command,timeout=timeout).stdout.decode()
    def write(self,target,data):
        with tempfile.NamedTemporaryFile() as f:
            f.write(data);f.flush();docker('cp',f.name,self.name+':'+target)
    def read(self,target,limit):
        # Use trusted guest helper to stat regular file and bound BEFORE transport.
        code="import os,stat,sys; p=sys.argv[1]; s=os.stat(p,follow_symlinks=False); assert stat.S_ISREG(s.st_mode) and s.st_size<=int(sys.argv[2]); sys.stdout.buffer.write(open(p,'rb').read())"
        result=docker('exec','--user','0','--workdir','/',self.name,'python3','-c',code,target,str(limit))
        if len(result.stdout)>limit: raise RuntimeError('Oversized output')
        return result.stdout
    def stop(self):
        # Kill every untrusted uid1000 process before touching files. No host PID access.
        self.cmd("python3 /opt/execution-pool/guest.py stop",root=True)
    def delete(self):
        result=docker('inspect',self.name,check=False)
        if result.returncode:
            # A responsive daemon must confirm no matching container, not merely an inspect error.
            return self.name not in docker('ps','-a','--format','{{.Names}}').stdout.decode().splitlines()
        metadata=json.loads(result.stdout)[0]
        if metadata['Config'].get('Labels',{}).get('execution-pool.creation')!=self.p['reservation']['creation_key']:
            raise RuntimeError('Wrong guest identity')
        docker('rm','-f',self.name)
        return self.name not in docker('ps','-a','--format','{{.Names}}').stdout.decode().splitlines()

class Cube:
    def __init__(self,p):
        self.p=p
        # Operator-configured root/service-owned env file; never a tenant-supplied URL/path.
        path=Path(p['node']['config']['environment_file'])
        st=path.stat()
        if st.st_mode & 0o077: raise RuntimeError('Unsafe provider credentials')
        for line in path.read_text().splitlines():
            if not line or line.startswith('#'):continue
            key,sep,value=line.partition('=')
            if sep and key in {'CUBE_API_URL','CUBE_API_KEY','CUBE_PROXY_NODE_IP','CUBE_PROXY_PORT_HTTP','CUBE_SANDBOX_DOMAIN'}:
                parsed=shlex.split(value)
                if len(parsed)!=1:raise RuntimeError('Invalid provider configuration')
                os.environ[key]=parsed[0]
        from cubesandbox import Sandbox,Config
        self.Sandbox,self.Config=Sandbox,Config
        self.vm=None
    def find(self):
        r=self.p['reservation']
        matches=[item for item in self.Sandbox.list() if item.get('metadata',{}).get('execution_pool_creation')==r['creation_key']]
        if len(matches)>1: raise RuntimeError('Ambiguous guest')
        if matches:self.vm=self.Sandbox(matches[0],config=self.Config())
        return self.vm
    def create(self):
        template=self.p['template']
        profile=template['network_profiles'][self.p['session']['network_profile']]
        # Default-deny network must be enforced by the admitted node. No SDK-level claim substitutes for admission.
        config=self.p['node']['config']
        if not config.get('admission_passed') or config.get('template_digest')!=template['image_digest']:
            raise RuntimeError('Node/template not admitted')
        expected={k:self.p['reservation'][k] for k in ['vcpus','memory_mib','disk_mib']}
        if config.get('resources')!=expected:raise RuntimeError('Reservation differs from admitted template')
        vm=self.Sandbox.create(template=config['cube_template_id'],timeout=14400,allow_internet_access=profile.get('allow_internet_access',False),
            metadata={'execution_pool_creation':self.p['reservation']['creation_key']},
            network={'deny_out':profile.get('deny_out',[])})
        self.vm=vm
        info=vm.get_info()
        self.validate_resources(info,expected)
        self.cmd('install -d /opt/execution-pool /run/task /run/secrets /workspace /tmp/pool-scratch; chmod 1777 /tmp/pool-scratch',root=True)
        for name in ['workspace.py','guest.py']:self.write('/opt/execution-pool/'+name,(ROOT/name).read_bytes())
        return vm.sandbox_id
    def validate_resources(self,info,expected):
        if info.cpu_count!=expected['vcpus'] or info.memory_mb!=expected['memory_mib']:
            raise RuntimeError('Actual guest resources differ')
        disk=info.disk_size_mb
        if disk in (None,0):
            # CubeAPI 0.7.3 reports a literal zero here. Its image template uses
            # /dev/vda as the writable layer. Verify the real block capacity as
            # root before uploading any tenant input; never trust zero as a match.
            code="from pathlib import Path; print(int(Path('/sys/class/block/vda/size').read_text())*512)"
            size=int(self.cmd(shell(['python3','-c',code]),root=True).strip())
            if size!=expected['disk_mib']*1024*1024:
                raise RuntimeError('Actual guest disk differs')
        elif disk!=expected['disk_mib']:
            raise RuntimeError('Actual guest disk differs')
    def require(self):
        if not self.vm:self.find()
        if not self.vm:raise RuntimeError('Guest unavailable')
        return self.vm
    def cmd(self,command,root=False,timeout=180):
        result=self.require().commands.run('cd /; export PATH=/usr/local/bundle/bin:/usr/local/bin:/usr/bin:/bin; '+command,user='root' if root else 'user',timeout=timeout,envs={'HOME':'/root' if root else '/home/user','LANG':'C.UTF-8','LC_ALL':'C.UTF-8'})
        if result.exit_code:raise RuntimeError('Guest helper failed')
        return result.stdout
    def write(self,target,data):self.require().files.write(target,data,user='root')
    def read(self,target,limit):
        code="import os,stat,sys; s=os.stat(sys.argv[1],follow_symlinks=False); assert stat.S_ISREG(s.st_mode) and s.st_size<=int(sys.argv[2])"
        self.cmd(shell(['python3','-c',code,target,str(limit)]),root=True)
        encoded=self.cmd(shell(['python3','-c',"import base64,sys; print(base64.b64encode(open(sys.argv[1],'rb').read()).decode())",target]),root=True)
        if len(encoded)>(limit*4//3+8):raise RuntimeError('Oversized encoded output')
        data=base64.b64decode(encoded.strip(),validate=True)
        if len(data)>limit:raise RuntimeError('Oversized output')
        return data
    def stop(self):self.cmd('python3 /opt/execution-pool/guest.py stop',root=True)
    def delete(self):
        vm=self.find()
        if not vm:
            # Unknown create outcomes retain capacity for the provider's possible delayed-create window.
            return bool(self.p['reservation'].get('provider_id'))
        vm.kill()
        self.vm=None
        return self.find() is None

def execute(provider,p):
    provider.stop()
    # Trusted helper resets even hostile filenames without interpreting shell data.
    provider.cmd('python3 /opt/execution-pool/guest.py reset',root=True)
    # Clear the retained VM journal before any new operation thread can start.
    provider.cmd('rm -f /run/pool-private/output.ndjson',root=True)
    provider.write('/run/task/input.tar.gz',Path(p['input_path']).read_bytes())
    if p.get('request_path'):provider.write('/run/task/request.json',Path(p['request_path']).read_bytes())
    secrets={}
    slots=p['template'].get('secret_slots',{})
    for slot,value in p.get('secrets',{}).items():
        if slot not in slots:raise RuntimeError('Secret slot forbidden')
        # Names never become arbitrary guest paths; mount below a fixed directory.
        if not slot.replace('_','').replace('-','').isalnum():raise RuntimeError('Invalid secret slot')
        provider.write('/run/secrets/'+slot,value.encode())
        secrets[slot]='/run/secrets/'+slot
    op=p['operation']
    provider.write('/run/task/control.json',json.dumps({'argv':op['argv'],'cwd':op['cwd'],'permission_profile':op['permission_profile'],'timeout_seconds':op['timeout_seconds'],'secret_paths':secrets}).encode())
    failure=[]
    def run_guest():
        try:provider.cmd('python3 /opt/execution-pool/guest.py execute',root=True,timeout=op['timeout_seconds']+30)
        except Exception:failure.append(True)
    thread=threading.Thread(target=run_guest,daemon=True)
    thread.start();emitted=0
    while thread.is_alive():
        thread.join(.5)
        try:
            records=provider.read('/run/pool-private/output.ndjson',8*MAX_LOG).decode().splitlines()
            # Ignore a partially written final line until the next read.
            for record in records[emitted:]:
                try:chunk=json.loads(record)
                except ValueError:break
                print(json.dumps({'type':'output','data':chunk}),flush=True);emitted+=1
        except Exception:pass
    if failure:raise RuntimeError('Guest execution uncertain')
    records=provider.read('/run/pool-private/output.ndjson',8*MAX_LOG).decode().splitlines()
    for record in records[emitted:]:print(json.dumps({'type':'output','data':json.loads(record)}),flush=True)
    provider.stop()
    status=json.loads(provider.read('/run/task/status.json',1048576))
    # Collect structured result before scrub, and stream bounds before any download.
    result=None
    if status.get('result_present'):
        result=json.loads(provider.read('/run/task/result.json',1048576))
        if not isinstance(result,dict):raise RuntimeError('Invalid result object')
    stdout=provider.read('/run/task/stdout',MAX_LOG).decode('utf-8','replace')
    stderr=provider.read('/run/task/stderr',MAX_LOG).decode('utf-8','replace')
    provider.cmd('python3 /opt/execution-pool/guest.py checkpoint',root=True)
    archive=provider.read('/run/pool-private/checkpoint.tar.gz',MAX_BYTES)
    # Revalidate guest output on trusted controller before it is eligible to publish.
    with tempfile.TemporaryDirectory() as folder:unpack(archive,folder)
    Path(p['output_dir'],'checkpoint.tar.gz').write_bytes(archive)
    provider.cmd('python3 /opt/execution-pool/guest.py scrub',root=True)
    return {'exit_code':status['exit_code'],'stdout':'','stderr':'','truncated':status.get('truncated',False),'result':result,'error_code':status.get('error_code')}


def main():
    action="initialize"
    started=time.monotonic()
    try:
        payload=json.load(sys.stdin)
        provider=Docker(payload) if payload['node']['provider']=='docker_test' else Cube(payload)
        action=payload['action']
        if action=='create':result={'provider_id':provider.create()}
        elif action=='execute':result=execute(provider,payload)
        elif action=='recover':
            exists=provider.find() if isinstance(provider,Cube) else docker('inspect',provider.name,check=False).returncode==0
            if exists:
                provider.stop()
                provider.cmd('python3 /opt/execution-pool/guest.py checkpoint',root=True)
                data=provider.read('/run/pool-private/checkpoint.tar.gz',MAX_BYTES)
                with tempfile.TemporaryDirectory() as folder:unpack(data,folder)
                Path(payload['output_dir'],'recovery.tar.gz').write_bytes(data)
            result={'exists':bool(exists)}
        elif action=='observe':
            if isinstance(provider,Cube):
                vm=provider.find()
                raw_state=vm.get_info().state if vm else None
                state='absent' if not vm else ('running' if getattr(raw_state,'value',raw_state)=='running' else 'unknown')
            else:
                listing=docker('ps','-a','--format','{{.Names}}').stdout.decode().splitlines()
                if provider.name not in listing:state='absent'
                else:
                    meta=json.loads(docker('inspect',provider.name).stdout)[0]
                    if meta['Config'].get('Labels',{}).get('execution-pool.creation')!=payload['reservation']['creation_key']:raise RuntimeError('Wrong guest identity')
                    state='running' if meta['State']['Running'] else 'unknown'
            result={'state':state}
        elif action=='delete':result={'confirmed':provider.delete()}
        else:raise RuntimeError('Unknown provider action')
        print(json.dumps({'type':'result','data':result}),flush=True)
    except Exception:
        # Only fixed protocol codes leave this process, never exception text.
        stage=action if action in {'create','execute','recover','delete','observe'} else 'initialize'
        print(json.dumps({'type':'error','data':{'code':'provider_'+stage+'_failed','stage':stage,'duration_ms':int((time.monotonic()-started)*1000)}}),flush=True)
        sys.exit(1)

if __name__=="__main__":main()
