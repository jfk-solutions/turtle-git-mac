#!/usr/bin/env python3
"""Private native branch/tag/worktree accepted-creation outcomes and cancellation."""
import argparse
import os
from pathlib import Path
import shutil
import tempfile
from native_receiver import build_receiver, run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
cache=root/'build/qa/creation-outcome-native-sources'
cache.mkdir(parents=True,exist_ok=True)
receiver=build_receiver(root,[root/'docs/qa/creation-outcome-native-2026-10-29.swift'],cache)
for index,git in enumerate(args.git or [Path('/usr/bin/git'),root/'build/git-runtime/Git/bin/git']):
    with tempfile.TemporaryDirectory(prefix='turtlegit-creation-outcome-') as temporary:
        folder=Path(temporary).resolve()
        for name in ['fixture','home/Library/Preferences','tmp','xdg']:(folder/name).mkdir(parents=True,mode=0o700)
        environment={key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
        environment.update(HOME=str(folder/'home'),CFFIXED_USER_HOME=str(folder/'home'),TMPDIR=str(folder/'tmp')+'/',XDG_CONFIG_HOME=str(folder/'xdg'),
                           GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',GIT_TERMINAL_PROMPT='0',
                           DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'))
        print('Checking native creation outcomes with '+str(git),flush=True)
        try:
            result=run_receiver([str(receiver),str(folder/'fixture'),str(git.absolute())],cwd=root,env=environment,capture_output=True,text=True,timeout=180,timeout_sample=folder/'timeout.sample.txt')
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS native creation outcomes:' not in result.stdout:raise RuntimeError('Creation receiver exited before final assertions/drain')
        except BaseException:
            evidence=Path(tempfile.mkdtemp(prefix='creation-outcome-failed-'+str(index)+'-',dir=root/'build/qa'))
            shutil.copytree(folder,evidence,dirs_exist_ok=True)
            print('Private failed creation evidence: '+str(evidence),flush=True)
            raise
