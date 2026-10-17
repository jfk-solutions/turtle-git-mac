#!/usr/bin/env python3
"""Native remaining URL/path word-command consumers."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-input-consumers-') as temporary:
    folder=Path(temporary)
    receiver=build_receiver(root,[root/'docs/qa/input-word-consumers-native-2026-10-17.swift'],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1')
    for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture=folder/str(index);fixture.mkdir()
        print('Checking native input word consumers with '+str(git),flush=True)
        result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if 'PASS: native revision/Open/Remote/ref-search/Log/rename/Merge Find word consumers' not in result.stdout:raise SystemExit('Input word receiver exited before completion.')
