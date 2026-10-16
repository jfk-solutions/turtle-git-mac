#!/usr/bin/env python3
"""Native cache tray menus/activity without installing a menu-bar item or login job."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--captures',type=Path);args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='TurtleGitCacheTray-') as temporary:
    folder=Path(temporary);receiver=build_receiver(root,[root/'docs/qa/cache-tray-native-2026-10-16.swift'],folder)
    env=os.environ.copy();env['DYLD_FRAMEWORK_PATH']=str(root/'build/Build/Products/Debug')
    if args.captures:args.captures.mkdir(parents=True,exist_ok=True);env['TURTLEGIT_CACHE_TRAY_CAPTURE']=str(args.captures.absolute())
    result=run_receiver([str(receiver),str(folder)],cwd=root,env=env,capture_output=True,text=True)
    print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
    if 'PASS: native cache activity/menu' not in result.stdout:raise SystemExit('Missing cache tray completion marker')
