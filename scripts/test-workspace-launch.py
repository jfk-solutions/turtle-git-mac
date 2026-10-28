#!/usr/bin/env python3
"""Universal scene cold-file routing and retained singleton workspace regression."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
from native_receiver import build_receiver, run_receiver

def retire_owned_helpers(context, approved_images):
    """Require both an exact executable and an open private fixture resource.

    Shell ownership additionally requires the exact authored wrapper argv. No
    unrelated application or process merely mentioning a fixture path is killed.
    """
    wrapper = context / 'fixture/held-helper'

    def owned():
        listing = subprocess.run(['/usr/sbin/lsof', '-t', '+D', str(context)],
                                 capture_output=True, text=True, timeout=10)
        if listing.returncode not in (0, 1):
            raise RuntimeError('Cannot inspect private handoff helper ownership')
        result = []
        for text in set(listing.stdout.split()):
            pid = int(text)
            executable = subprocess.run(['/usr/sbin/lsof', '-a', '-p', str(pid), '-d', 'txt', '-Fn'],
                                        capture_output=True, text=True, timeout=5)
            images = {str(Path(line[1:]).resolve()) for line in executable.stdout.splitlines() if line.startswith('n')}
            if images.intersection(approved_images):
                result.append(pid)
            elif str(Path('/bin/sh').resolve()) in images or '/bin/bash' in images:
                args = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'command='],
                                      capture_output=True, text=True, timeout=5).stdout.strip()
                if args.startswith('/bin/sh ' + str(wrapper) + ' ') or args == '/bin/sh ' + str(wrapper):
                    result.append(pid)
        return result

    needed = bool(owned())
    for number in (signal.SIGTERM, signal.SIGKILL):
        for pid in owned():
            if pid not in owned():
                continue
            try:
                group = os.getpgid(pid)
                os.killpg(group, number) if group == pid else os.kill(pid, number)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 3
        while owned() and time.monotonic() < deadline:
            time.sleep(.03)
        if not owned():
            return needed
    raise RuntimeError('Verified private handoff producer survived cleanup')


parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--only',choices=['cold','late','workspace','action-only','action-cancel','action-error','late-default','url-registration','finder-argv','finder-url-first','finder-authority-gate','finder-missing','finder-commit','finder-prioritized-authority','startup-lock','startup-config-gate','dialog-first-read'],action='append')
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
generated=root/'build/qa/workspace-launch-native-sources'
generated.mkdir(parents=True,exist_ok=True)
receiver=build_receiver(root,[root/'docs/qa/workspace-launch-native-2026-10-25.swift',root/'docs/qa/finder-cold-start-native-2026-10-28.swift',root/'docs/qa/dialog-first-read-native-2026-10-28.swift'],generated)
results=[]
for git in args.git or [Path('/usr/bin/git'),root/'build/git-runtime/Git/bin/git']:
 git=git.absolute()
 for case in args.only or ['cold','late','workspace','action-only','action-cancel','action-error','late-default','url-registration','finder-argv','finder-url-first','finder-authority-gate','finder-missing','finder-commit','finder-prioritized-authority','startup-lock','startup-config-gate']:
  with tempfile.TemporaryDirectory(prefix='turtlegit-workspace-launch-') as temporary:
   context=Path(temporary).resolve()
   for name in ['fixture','preferences','xdg','temporary','home']:(context/name).mkdir(mode=0o700)
   config=context/'global.config';config.write_text('')
   env={k:v for k,v in os.environ.items() if not k.startswith('GIT_')}
   env.update(GIT_CONFIG_GLOBAL=str(config),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',HOME=str(context/'home'),CFFIXED_USER_HOME=str(context/'preferences'),XDG_CONFIG_HOME=str(context/'xdg'),TMPDIR=str(context/'temporary')+'/',DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'))
   print('Checking workspace launch '+case+' with '+str(git),flush=True)
   passed=False
   try:
    result=run_receiver([str(receiver),str(context/'fixture'),str(git),case],cwd=root,env=env,capture_output=True,text=True,timeout_sample=context/'timeout.sample.txt')
    print(result.stdout,end='');print(result.stderr,end='')
    passed=result.returncode==0 and 'PASS: workspace launch '+case in result.stdout
    results.append(dict(git=str(git),case=case,returncode=result.returncode,passed=passed))
    (root/'build/qa/workspace-launch-native-results.json').write_text(json.dumps(results,indent=2)+'\n')
    result.check_returncode()
    if not passed:raise RuntimeError('Workspace launch case did not complete')
   finally:
    sample=context/'timeout.sample.txt'
    if sample.is_file():shutil.copy2(sample,root/('build/qa/workspace-launch-'+case+'-'+git.parent.name+'-timeout.sample.txt'))
    approved={str(git.resolve())}
    helpers=root/'build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers'
    if helpers.is_dir():approved.update(str(path.resolve()) for path in helpers.rglob('*') if path.is_file() and os.access(path,os.X_OK))
    needed=retire_owned_helpers(context,approved)
    if passed and needed:
     results[-1].update(passed=False,helper_cleanup_needed=True)
     (root/'build/qa/workspace-launch-native-results.json').write_text(json.dumps(results,indent=2)+'\n')
     raise RuntimeError('Successful workspace launch left owned helpers')
