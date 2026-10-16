#!/usr/bin/env python3
"""Prepared and renamed gitlink comparisons, retained submodule owners and Revert file commands."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--capture-dir',type=Path)
parser.add_argument('--only',choices=['prepared','handoffs','revert'],action='append')
args=parser.parse_args();root=Path(__file__).resolve().parent.parent
cases=[('prepared','prepared-submodule-native-2026-10-16.swift','PASS prepared submodules:'),('handoffs','submodule-handoffs-native-2026-10-14.swift','Submodule handoffs:'),('revert','revert-file-commands-native-2026-10-16.swift','PASS Revert file commands:')]
with tempfile.TemporaryDirectory(prefix='tg-prepared-submodules-') as temporary:
    directory=Path(temporary);env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for case,source,marker in cases:
        if args.only and case not in args.only:continue
        receiver=build_receiver(root,[root/'docs/qa'/source],directory)
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture=directory/(case+str(index));fixture.mkdir()
            run_env=env.copy()
            if args.capture_dir and case == 'prepared' and index == 0:run_env['TURTLEGIT_SUBMODULE_CAPTURE_DIR']=str(args.capture_dir.absolute())
            result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=run_env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if marker not in result.stdout:raise SystemExit('Receiver exited before final assertion: '+case)
