#!/usr/bin/env python3
"""Byte-backed native unified diff editing, saves and Undo."""
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
with tempfile.TemporaryDirectory(prefix='turtlegit-byte-buffer-') as temporary:
    folder=Path(temporary)
    receiver=build_receiver(root,[root/'docs/qa/unified-byte-buffer-native-2026-10-17.swift'],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1')
    for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture=folder/str(index);fixture.mkdir()
        if args.captures and index==0:
            args.captures.mkdir(parents=True,exist_ok=True);env['TURTLEGIT_BYTE_BUFFER_CAPTURE']=str(args.captures.absolute())
        else:env.pop('TURTLEGIT_BYTE_BUFFER_CAPTURE',None)
        print('Checking unified byte buffer with '+str(git),flush=True)
        result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if 'PASS: native mixed UTF8/regional/opaque edits' not in result.stdout:raise SystemExit('Unified byte buffer receiver exited before completion.')
