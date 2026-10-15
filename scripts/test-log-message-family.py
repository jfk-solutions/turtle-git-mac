#!/usr/bin/env python3
"""Native Log message links, source formatting and lifecycle family."""
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
with tempfile.TemporaryDirectory(prefix='turtlegit-log-message-') as temporary:
    folder=Path(temporary);inputs=root/'build/qa/log-message-fixtures';inputs.mkdir(parents=True,exist_ok=True)
    source=inputs/'log-message-native-2026-10-15.swift';source.write_text((root/'docs/qa'/source.name).read_text())
    receiver=build_receiver(root,[source],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture=folder/str(index);fixture.mkdir();env.pop('TURTLEGIT_LOG_MESSAGE_CAPTURE',None)
        if args.captures and index==0:
            args.captures.mkdir(parents=True,exist_ok=True);env['TURTLEGIT_LOG_MESSAGE_CAPTURE']=str(args.captures.absolute())
        print('Checking Log message family with '+str(git),flush=True)
        result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if 'PASS: Log rich message source links/traits/highlights' not in result.stdout:raise SystemExit('Log message receiver exited before completion.')
