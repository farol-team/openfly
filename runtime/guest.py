#!/usr/bin/env python3
"""Root-owned helper installed outside workspace. Never import client code."""
import ctypes
import json
import os
import resource
import selectors
import codecs
import shutil
import signal
import stat
import subprocess
import sys
import time
from pathlib import Path
sys.path.insert(0,'/opt/execution-pool')
from workspace import pack,unpack
TASK=Path('/run/task')
WORK=Path('/workspace')
UID=1000
PRIVATE=Path('/run/pool-private')
PRIVATE.mkdir(mode=0o700,exist_ok=True)
assert PRIVATE.is_dir() and not PRIVATE.is_symlink() and PRIVATE.stat().st_uid==0
PRIVATE.chmod(0o700)

def stop():
    for path in Path('/proc').iterdir():
        if not path.name.isdigit():continue
        try:
            if path.stat().st_uid==UID:os.kill(int(path.name),signal.SIGKILL)
        except (ProcessLookupError,FileNotFoundError,PermissionError):pass
    # Do not race extraction with descendants still exiting.
    for _ in range(50):
        alive=False
        for path in Path('/proc').iterdir():
            if not path.name.isdigit():continue
            try:
                if path.stat().st_uid==UID and ') Z ' not in (path/'stat').read_text():alive=True
            except (ProcessLookupError,FileNotFoundError,PermissionError):pass
        if not alive:return
        time.sleep(.02)
    raise RuntimeError('Guest process cleanup not confirmed')

def remove(path):
    if path.is_symlink() or not path.is_dir():path.unlink(missing_ok=True)
    else:shutil.rmtree(path)

def scrub():
    for name in ['/home/user/.codex','/home/user/.claude','/tmp/pool-scratch/.codex','/tmp/pool-scratch/.claude']:
        remove(Path(name))
    for root in [TASK,Path('/run/secrets')]:
        for p in root.iterdir():remove(p)

def reset():
    stop();scrub()
    for p in WORK.iterdir():remove(p)

def execute():
    control=json.loads((TASK/'control.json').read_text())
    unpack((TASK/'input.tar.gz').read_bytes(),WORK)
    readonly=control['permission_profile']=='workspace-read'
    modes={}
    for path in [WORK,*WORK.rglob('*')]:
        if path.is_symlink():continue
        modes[str(path)]=stat.S_IMODE(path.stat().st_mode)
        os.chown(path,0 if readonly else UID,0 if readonly else UID)
        path.chmod(((modes[str(path)] & ~0o222) | (0o555 if path.is_dir() else 0o444)) if readonly else modes[str(path)] | 0o600 | (0o100 if path.is_dir() else 0))
    (TASK/'modes.json').write_text(json.dumps(modes))
    TASK.chmod(0o755)
    (TASK/'control.json').chmod(0o600)
    if (TASK/'request.json').exists():(TASK/'request.json').chmod(0o444)
    (TASK/'input.tar.gz').chmod(0o600)
    result=TASK/'result.json'
    result.touch();os.chown(result,UID,UID);result.chmod(0o600)
    secrets=Path('/run/secrets');secrets.chmod(0o711)
    for path in secrets.iterdir():os.chown(path,UID,UID);path.chmod(0o400)
    env={'PATH':'/usr/local/bundle/bin:/usr/local/bin:/usr/bin:/bin','HOME':'/tmp/pool-scratch','LANG':'C.UTF-8','LC_ALL':'C.UTF-8','POOL_REQUEST_PATH':'/run/task/request.json','POOL_RESULT_PATH':'/run/task/result.json'}
    for slot,path in control.get('secret_paths',{}).items():env['POOL_SECRET_'+slot.upper()+'_PATH']=path
    def drop():
        os.setgroups([]);os.setgid(UID);os.setuid(UID)
        ctypes.CDLL(None).prctl(38,1,0,0,0) # PR_SET_NO_NEW_PRIVS
        resource.setrlimit(resource.RLIMIT_CORE,(0,0))
        os.umask(0o077)
    code=1;error=None;truncated=False
    # Collector limits output independently of project files/build artifacts.
    spool=PRIVATE/'output.ndjson'
    spool.unlink(missing_ok=True)
    with spool.open('x') as journal,(TASK/'stdout').open('wb') as out,(TASK/'stderr').open('wb') as err:
        total=0
        try:
            process=subprocess.Popen(control['argv'],cwd='/workspace',env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,preexec_fn=drop,start_new_session=True)
            selector=selectors.DefaultSelector()
            selector.register(process.stdout,selectors.EVENT_READ,('stdout',out))
            selector.register(process.stderr,selectors.EVENT_READ,('stderr',err))
            deadline=time.monotonic()+control['timeout_seconds']
            while selector.get_map():
                if time.monotonic()>deadline:
                    os.killpg(process.pid,signal.SIGKILL);error='execution_timeout'
                    deadline=float('inf')
                for key,_ in selector.select(.1):
                    data=os.read(key.fileobj.fileno(),8192)
                    if not data:
                        selector.unregister(key.fileobj);continue
                    remaining=max(0,1024*1024-total)
                    truncated |= len(data)>remaining
                    data=data[:remaining];total+=len(data)
                    if data:
                        name,target=key.data
                        target.write(data);target.flush()
                        journal.write(json.dumps({'stream':name,'text':data.decode('utf-8','replace')})+'\n');journal.flush()
            code=process.wait()
            if error:code=124
        except OSError:
            code=127;error='command_start_failed'
    stop()
    # Restore original mode bits for read-only checks after stopping all user processes.
    if readonly:
        for name,mode in modes.items():
            path=Path(name)
            if path.exists() and not path.is_symlink():path.chmod(mode)
    result_present=result.stat().st_size>0
    if result_present:
        try:
            if result.stat().st_size>1048576 or not isinstance(json.loads(result.read_text()),dict):raise ValueError()
        except (ValueError,UnicodeError):result_present=False;code=1;error='invalid_result'
    (TASK/'status.json').write_text(json.dumps({'exit_code':code,'error_code':error,'result_present':result_present,'truncated':truncated}))

if __name__=='__main__':
    action=sys.argv[1]
    if action=='stop':stop()
    elif action=='scrub':scrub()
    elif action=='reset':reset()
    elif action=='execute':execute()
    elif action=='checkpoint':
        stop()
        output=PRIVATE/'checkpoint.tar.gz'
        output.unlink(missing_ok=True)
        with output.open('xb') as f:
            f.write(pack(WORK));f.flush();os.fsync(f.fileno())
    else:raise ValueError('Unknown helper')
