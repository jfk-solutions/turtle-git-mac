#!/usr/bin/env python3
"""Native Log exact selection, parent groups and captured file actions."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--git',type=Path,action='append');args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-log-file-identities-') as temporary:
    directory=Path(temporary);receiver=build_receiver(root,[root/'docs/qa/log-file-identities-native-2026-10-17.swift'],directory)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture=directory/str(index);fixture.mkdir();print('Checking Log file identities '+str(git),flush=True)
        result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if 'PASS Log file identities:' not in result.stdout:raise SystemExit('Receiver exited before completion')
