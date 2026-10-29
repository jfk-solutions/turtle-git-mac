#!/usr/bin/env python3
"""Private native standalone/rebound saved-output Mark Resolved workflow."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--only',choices=['read-only'])
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
generated=root/'build/qa/merge-saved-resolve-sources'
generated.mkdir(parents=True,exist_ok=True)
receiver=build_receiver(root,[root/'docs/qa/merge-saved-resolve-native-2026-10-29.swift'],generated)
for git in args.git or [Path('/usr/bin/git'),root/'build/git-runtime/Git/bin/git']:
    with tempfile.TemporaryDirectory(prefix='TurtleGitSavedResolve-') as temporary:
        context=Path(temporary)
        for name in ['fixture','preferences','home','xdg','temporary']:(context/name).mkdir(mode=0o700)
        config=context/'global.config';config.write_text('')
        env={key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
        env.update(GIT_CONFIG_GLOBAL=str(config),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',HOME=str(context/'home'),CFFIXED_USER_HOME=str(context/'preferences'),XDG_CONFIG_HOME=str(context/'xdg'),TMPDIR=str(context/'temporary')+'/',DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'))
        print('Checking saved-output Resolve with '+str(git),flush=True)
        result=run_receiver([str(receiver),str(context/'fixture'),str(git.absolute())]+([args.only] if args.only else []),cwd=root,env=env,capture_output=True,text=True,timeout=180,timeout_sample=context/'timeout.sample.txt')
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if 'PASS: saved three-pane Resolve' not in result.stdout:raise RuntimeError('Saved Resolve fixture did not complete')
