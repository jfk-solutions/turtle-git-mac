#!/usr/bin/env python3
"""Grouped native primary dialog layout and live presentation; current Debug objects."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--capture-dir',type=Path)
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-primary-live-') as temporary:
    folder=Path(temporary)
    receiver=build_receiver(root,[root/'docs/qa/primary-live-presentation-native-2026-10-16.swift'],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture=folder/str(index);fixture.mkdir()
        if args.capture_dir and index==0:env['TURTLEGIT_PRIMARY_CAPTURE_DIR']=str(args.capture_dir.resolve())
        else:env.pop('TURTLEGIT_PRIMARY_CAPTURE_DIR',None)
        result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if 'PASS: adaptive Commit' not in result.stdout:raise SystemExit('Receiver exited before final assertion.')
