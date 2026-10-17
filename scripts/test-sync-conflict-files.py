#!/usr/bin/env python3
"""Grouped actual Sync conflict file table, shared actions and owned native chooser checks."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--git',action='append',type=Path);p.add_argument('--captures',type=Path);args=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-sync-conflict-files-') as temp:
    folder=Path(temp);binary=build_receiver(root,[root/'docs/qa/sync-conflict-files-native-2026-10-17.swift'],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture=folder/('fixture-'+str(index));fixture.mkdir();env.pop('TURTLEGIT_SYNC_CONFLICT_CAPTURE',None)
        if args.captures and index==0:env['TURTLEGIT_SYNC_CONFLICT_CAPTURE']=str(args.captures.resolve())
        print('Checking Sync conflict files '+str(git),flush=True)
        r=run_receiver([str(binary),str(fixture),str(git.resolve())],cwd=root,env=env,capture_output=True,text=True)
        print(r.stdout,end='');print(r.stderr,end='');r.check_returncode()
        if 'PASS Sync conflict files' not in r.stdout:raise SystemExit('Receiver exited without completion marker')
