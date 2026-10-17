#!/usr/bin/env python3
"""Native Add/Revert ordered acceptance, owned file panels and launch lifetime."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--git',type=Path,action='append');args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-add-revert-flow-') as temporary:
    directory=Path(temporary);receiver=build_receiver(root,[root/'docs/qa/add-revert-file-flow-native-2026-10-17.swift'],directory)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture=directory/str(index);fixture.mkdir();print('Checking Add/Revert file flow '+str(git),flush=True)
        result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if 'PASS Add/Revert file flow:' not in result.stdout:raise SystemExit('Receiver exited before completion')
