#!/usr/bin/env python3
"""Grouped Resolve scope/drop/keyboard checks and retained resolution progress."""
import argparse
import os
import tempfile
from pathlib import Path
from native_receiver import build_receiver, run_receiver

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--only',choices=['files','drop','progress'],action='append')
args=parser.parse_args();root=Path(__file__).resolve().parent.parent
cases={'files':('resolve-file-menu-native-2026-10-16.swift','PASS: Resolve captured source file menu'),
       'drop':('resolve-drop-native-2026-10-16.swift','PASS: Resolve same-repository'),
       'progress':('resolve-progress-native-2026-10-14.swift','Resolve streamed real checked')}
with tempfile.TemporaryDirectory(prefix='tg-resolve-family-') as temporary:
    directory=Path(temporary)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for case in args.only or cases:
        source,marker=cases[case]
        binary=build_receiver(root,[root/'docs/qa'/source],directory)
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture=directory/(case+str(index));fixture.mkdir()
            print('Checking Resolve '+case+' with '+str(git),flush=True)
            result=run_receiver([str(binary),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if marker not in result.stdout:raise SystemExit('Resolve receiver exited without completion: '+case)
