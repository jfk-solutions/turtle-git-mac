#!/usr/bin/env python3
"""Grouped native Synchronization child progress checks on private repositories."""
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
with tempfile.TemporaryDirectory(prefix='turtlegit-sync-child-') as temporary:
    folder=Path(temporary)
    receiver=build_receiver(root,[root/'docs/qa/sync-child-progress-native-2026-10-17.swift'],folder)
    env=os.environ.copy();env['DYLD_FRAMEWORK_PATH']=str(root/'build/Build/Products/Debug')
    for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture=folder/('fixture-'+str(index));fixture.mkdir()
        env.pop('TURTLEGIT_SYNC_CHILD_CAPTURE',None)
        if args.captures and index==0:env['TURTLEGIT_SYNC_CHILD_CAPTURE']=str(args.captures.resolve())
        print('Checking Sync child progress '+str(git),flush=True)
        result=run_receiver([str(receiver),str(fixture),str(git.resolve())],cwd=root,env=env,capture_output=True,text=True)
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if 'PASS Sync child progress' not in result.stdout:raise SystemExit('Receiver exited without completion marker')
