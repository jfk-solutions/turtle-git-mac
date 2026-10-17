#!/usr/bin/env python3
"""Regional raw patch presentation and editable document workflows."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--captures',type=Path)
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-raw-patch-codec-') as temporary:
    folder=Path(temporary)
    receiver=build_receiver(root,[root/'docs/qa/raw-patch-codec-native-2026-10-17.swift'],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1')
    for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture=folder/str(index);fixture.mkdir()
        if args.captures and index==0:
            args.captures.mkdir(parents=True,exist_ok=True);env['TURTLEGIT_RAW_PATCH_CAPTURE']=str(args.captures.absolute())
        else:env.pop('TURTLEGIT_RAW_PATCH_CAPTURE',None)
        print('Checking raw patch codecs with '+str(git),flush=True)
        result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if 'PASS: raw patch codecs' not in result.stdout:raise SystemExit('Raw patch receiver exited before completion.')
