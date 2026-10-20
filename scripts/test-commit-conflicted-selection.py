#!/usr/bin/env python3
"""Grouped conflicted Commit selection, warning, staging and owner lifetime checks."""
import argparse, os, tempfile
from pathlib import Path
from native_receiver import build_receiver, run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--captures',type=Path)
parser.add_argument('--only',choices=['selection','warning','staging','ownership'],action='append')
args=parser.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-commit-conflicted-') as temporary:
    directory=Path(temporary)
    receiver=build_receiver(root,[root/'docs/qa/commit-conflicted-selection-native-2026-10-21.swift'],directory)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    if args.captures:
        args.captures.mkdir(parents=True,exist_ok=True);env['TURTLEGIT_COMMIT_CONFLICT_CAPTURES']=str(args.captures.absolute())
    for case in args.only or ['selection','warning','staging','ownership']:
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture=directory/(case+str(index));fixture.mkdir()
            result=run_receiver([str(receiver),str(fixture),str(git.absolute()),case],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: conflicted Commit '+case not in result.stdout:raise SystemExit('Receiver exited before final assertions: '+case)
