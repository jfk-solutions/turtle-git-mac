#!/usr/bin/env python3
"""Exercise embedded SSH agent/key-loader/response tools with disposable keys."""
import argparse
import os
from pathlib import Path
import platform
import signal
import subprocess
import tempfile
import time
ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app',type=Path,default=ROOT/'build-store/Build/Products/AppStore/TurtleGitMac.app')
args = parser.parse_args(); app = args.app.resolve(); products = app.parent
frameworks = app/'Contents/Frameworks'
def running(pid):
    try: os.kill(pid,0)
    except ProcessLookupError: return False
    return True

def verify_cleanup(root):
    groups = [(int(p.read_text().strip()),[int(p.read_text().strip())],'agent') for p in root.glob('agent-monitor*.pid')]
    started = root/'slow-add.started'
    if started.exists():
        members = [int(value) for value in started.read_text().split()]
        assert len(members) == 2
        groups.append((members[0],members,'loader'))
    leaked = []
    for leader,members,kind in groups:
        alive = [pid for pid in members if running(pid)]
        if not alive: continue
        # Check group membership against the private fixture-created PID registry.
        for pid in alive:
            command = subprocess.check_output(['ps','-p',str(pid),'-o','comm='],text=True).strip()
            arguments = subprocess.check_output(['ps','-p',str(pid),'-o','args='],text=True)
            assert os.getpgid(pid) == leader, 'Refusing unrelated process group cleanup'
            if kind == 'agent':
                assert command == str(app/'Contents/Helpers/OpenSSH/bin/ssh-agent') and str(root) in arguments
            elif pid == leader:
                assert Path(command).name in ['sh','bash','slow-add'] and str(root/'slow-add') in arguments
            else:
                assert Path(command).name == 'sleep' and '30' in arguments, 'Refusing unrelated child cleanup'
        leaked.extend(alive)
        os.killpg(leader,signal.SIGTERM)
        deadline = time.monotonic()+2
        while any(running(pid) for pid in members) and time.monotonic()<deadline: time.sleep(.02)
        if any(running(pid) for pid in members):
            os.killpg(leader,signal.SIGKILL)
            deadline = time.monotonic()+2
            while any(running(pid) for pid in members) and time.monotonic()<deadline: time.sleep(.02)
    assert not leaked, 'Receiver left owned SSH processes running; emergency cleanup performed'
    assert not list(root.glob('tg-agent-*')), 'Receiver left private response/agent directories'

# Short paths are required by sockaddr_un; these private directories are mode 0700.
for inject_failure in [False,True]:
    with tempfile.TemporaryDirectory(prefix='tg-ssh-bundle-',dir='/tmp') as temporary:
        root = Path(temporary); receiver = root/'receiver'
        subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','5','-target',platform.machine()+'-apple-macos13.0','-I',products,'-F',products,ROOT/'docs/qa/bundled-ssh-agent-2026-10-10.swift','-framework','TurtleGitCore','-o',receiver],check=True)
        env = os.environ.copy(); env['DYLD_FRAMEWORK_PATH'] = str(frameworks)
        arguments = [receiver,app,root]+(['inject-live-failure'] if inject_failure else [])
        try:
            result = subprocess.run(arguments,env=env,cwd=root,capture_output=True,text=True,timeout=30)
            if inject_failure:
                assert result.returncode == 1 and 'Injected live-loading fixture failure' in result.stderr, result.stderr
                print('Native bundled agent: injected live-loading failure exits cleanly with owned agent/loader/child and response directory cleanup.')
            else:
                assert result.returncode == 0, result.stderr
                print(result.stdout.strip())
        finally: verify_cleanup(root)
    assert not Path(temporary).exists()
