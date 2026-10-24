#!/usr/bin/env python3
"""Private native Push namespace/removal and source-picker workflows."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
from native_receiver import build_receiver, run_receiver


def retire_owned_helpers(context, approved):
    """Git creates its own group; require its image AND private request resource."""
    def owned():
        listing = subprocess.run(['/usr/sbin/lsof','-t','+D',str(context)],capture_output=True,text=True,timeout=10)
        if listing.returncode not in (0,1):raise RuntimeError('Cannot inspect private Push helper ownership')
        result = []
        for value in set(listing.stdout.split()):
            pid = int(value)
            images = subprocess.run(['/usr/sbin/lsof','-a','-p',str(pid),'-d','txt','-Fn'],capture_output=True,text=True,timeout=5)
            actual = {str(Path(line[1:]).resolve()) for line in images.stdout.splitlines() if line.startswith('n')}
            if actual.intersection(approved):result.append(pid)
        return result
    remaining = owned();needed = bool(remaining)
    for action in [signal.SIGTERM,signal.SIGKILL]:
        for pid in remaining:
            if pid not in owned():continue
            try:
                os.killpg(pid,action) if os.getpgid(pid) == pid else os.kill(pid,action)
            except ProcessLookupError:pass
        deadline = time.monotonic()+3
        while time.monotonic() < deadline:
            remaining = owned()
            if not remaining:break
            time.sleep(.03)
        if not remaining:return needed
    raise RuntimeError('Owned Push helper survived cleanup: '+str(remaining))

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--only',choices=['namespace','removal','pickers'],action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
cache = root/'build/qa/push-destination-native-sources'
cache.mkdir(parents=True,exist_ok=True)
results = []
for case in args.only or ['namespace','removal','pickers']:
    source = 'push-source-pickers-native-2026-10-08.swift' if case == 'pickers' else 'push-destination-native-2026-10-24.swift'
    receiver = build_receiver(root,[root/'docs/qa'/source],cache)
    for git in args.git or [Path('/usr/bin/git'),root/'build/git-runtime/Git/bin/git']:
        with tempfile.TemporaryDirectory(prefix='turtlegit-push-destination-') as temporary:
            context = Path(temporary)
            env = {k:v for k,v in os.environ.items() if not k.startswith('GIT_')}
            for name,key in [('home','HOME'),('preferences','CFFIXED_USER_HOME'),('xdg','XDG_CONFIG_HOME'),('temporary','TMPDIR')]:
                folder = context/name;folder.mkdir(mode=0o700);env[key] = str(folder)+('/' if key == 'TMPDIR' else '')
            fixture = context/'fixture';fixture.mkdir(mode=0o700)
            env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
            command = [str(receiver),str(fixture),str(git.absolute())]
            if case != 'pickers':command.append(case)
            print('Checking Push destination '+case+' with '+str(git),flush=True)
            approved = {str(git.resolve())}
            resolved = subprocess.run(['/usr/bin/xcrun','--find','git'],capture_output=True,text=True)
            if resolved.returncode == 0:approved.add(str(Path(resolved.stdout.strip()).resolve()))
            passed = False
            try:
                result = run_receiver(command,cwd=root,env=env,capture_output=True,text=True,timeout_sample=root/('build/qa/push-destination-'+case+'.sample.txt'))
                print(result.stdout,end='');print(result.stderr,end='')
                passed = result.returncode == 0 and ('PASS: Push destination native '+case in result.stdout if case != 'pickers' else 'explicit OK publishes chosen old commit passed' in result.stdout)
                results.append(dict(case=case,git=str(git.absolute()),returncode=result.returncode,passed=passed))
                (root/'build/qa/push-destination-native-results.json').write_text(json.dumps(results,indent=2)+'\n')
                result.check_returncode()
                if not passed:raise SystemExit('Receiver exited without completion')
            finally:
                if retire_owned_helpers(context,approved) and passed:
                    results[-1].update(passed=False,helper_cleanup_needed=True)
                    (root/'build/qa/push-destination-native-results.json').write_text(json.dumps(results,indent=2)+'\n')
                    raise RuntimeError('Completed Push request left a helper running')
