#!/usr/bin/env python3
"""Grouped native compared-range history and exact file workflow."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append');parser.add_argument('--captures',type=Path)
args=parser.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-comparison-workflow-') as temporary:
    directory=Path(temporary);receiver=build_receiver(root,[root/'docs/qa/comparison-workflow-native-2026-10-17.swift'],directory)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture=directory/str(index);fixture.mkdir();env.pop('TURTLEGIT_COMPARISON_WORKFLOW_CAPTURE',None)
        if args.captures and index==0:
            args.captures.mkdir(parents=True,exist_ok=True);env['TURTLEGIT_COMPARISON_WORKFLOW_CAPTURE']=str(args.captures.resolve())
        print('Checking Comparison workflow '+str(git),flush=True)
        result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if 'PASS Comparison workflow:' not in result.stdout:raise SystemExit('Receiver exited before completion')
