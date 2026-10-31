#!/usr/bin/env python3
"""Native Apple support report import, review and export ownership."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--captures',type=Path)
args=parser.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-support-report-') as temporary:
    folder=Path(temporary);receiver=build_receiver(root,[root/'docs/qa/support-report-native-2026-10-17.swift'],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_SYSTEM=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',GIT_CONFIG_PARAMETERS='')
    for index in range(1):
        fixture=folder/str(index);fixture.mkdir()
        for name in ('home','preferences','xdg','tmp'):(fixture/name).mkdir()
        env.update(HOME=str(fixture/'home'),CFFIXED_USER_HOME=str(fixture/'preferences'),XDG_CONFIG_HOME=str(fixture/'xdg'),TMPDIR=str(fixture/'tmp'))
        env.pop('TURTLEGIT_SUPPORT_CAPTURE',None)
        if args.captures and index==0:
            args.captures.mkdir(parents=True,exist_ok=True);env['TURTLEGIT_SUPPORT_CAPTURE']=str(args.captures.absolute())
        print('Checking native Support report',flush=True)
        result=run_receiver([str(receiver),str(fixture)],cwd=root,env=env,capture_output=True,text=True)
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if 'PASS: Native support report' not in result.stdout:raise SystemExit('Support report receiver exited before completion.')
