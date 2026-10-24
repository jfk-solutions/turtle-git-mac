#!/usr/bin/env python3
"""Owned native historical navigation, reference creation and transport handoff workflows."""
import argparse
import json
import os
import signal
import subprocess
import time
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

def retire_owned_helpers(context, approved):
    """Git creates its own group; require its image AND private request resource."""
    def owned():
        listing = subprocess.run(['/usr/sbin/lsof','-t','+D',str(context)],capture_output=True,text=True,timeout=10)
        if listing.returncode not in (0,1):raise RuntimeError('Cannot inspect private historical navigation helper ownership')
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
    raise RuntimeError('Owned historical navigation helper survived cleanup: '+str(remaining))

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['log', 'browser', 'submodule', 'bisect'], action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
cache = root/'build/qa/historical-navigation-native-sources'
cache.mkdir(parents=True, exist_ok=True)
receiver = build_receiver(root, [root/'docs/qa/historical-navigation-native-2026-10-24.swift',root/'docs/qa/historical-bisect-native-2026-10-24.swift'], cache)
results = []
for case in args.only or ['log', 'browser', 'submodule', 'bisect']:
    for git in args.git or [Path('/usr/bin/git'), root/'build/git-runtime/Git/bin/git']:
        with tempfile.TemporaryDirectory(prefix='turtlegit-historical-navigation-') as temporary:
            context = Path(temporary)
            env = {k:v for k,v in os.environ.items() if not k.startswith('GIT_')}
            for name, key in [('home','HOME'), ('preferences','CFFIXED_USER_HOME'), ('xdg','XDG_CONFIG_HOME'), ('temporary','TMPDIR')]:
                folder = context/name; folder.mkdir(mode=0o700)
                env[key] = str(folder)+('/' if key == 'TMPDIR' else '')
            fixture = context/'fixture'; fixture.mkdir(mode=0o700)
            env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
            print('Checking historical navigation '+case+' with '+str(git), flush=True)
            approved = {str(git.resolve()),str((root/"build/libgit2-runtime/LibGit2/bin/turtlegit-libgit2").resolve()),str((fixture/"historical-helper").resolve()),str((fixture/"git-wrapper").resolve()),str((fixture/"bisect-helper").resolve()),"/bin/sh"}
            resolved = subprocess.run(['/usr/bin/xcrun','--find','git'], capture_output=True, text=True)
            if resolved.returncode == 0: approved.add(str(Path(resolved.stdout.strip()).resolve()))
            passed = False
            try:
                result = run_receiver([str(receiver), str(fixture), str(git.absolute()), case], cwd=root, env=env, capture_output=True, text=True,
                                      timeout_sample=root/('build/qa/historical-navigation-'+case+'.sample.txt'))
                print(result.stdout, end=''); print(result.stderr, end='')
                passed = result.returncode == 0 and ('PASS: historical navigation '+case) in result.stdout
                results.append(dict(case=case, git=str(git.absolute()), returncode=result.returncode, passed=passed))
                (root/'build/qa/historical-navigation-native-results.json').write_text(json.dumps(results, indent=2)+'\n')
                result.check_returncode()
                if not passed: raise RuntimeError('Receiver exited before final assertions: '+case)
            finally:
                if retire_owned_helpers(context, approved) and passed:
                    results[-1].update(passed=False, helper_cleanup_needed=True)
                    (root/'build/qa/historical-navigation-native-results.json').write_text(json.dumps(results, indent=2)+'\n')
                    raise RuntimeError('Completed historical navigation request left an owned Git helper running')
