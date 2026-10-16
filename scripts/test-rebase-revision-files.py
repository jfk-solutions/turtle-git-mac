#!/usr/bin/env python3
"""Connected Rebase Revision Files and retained Changed Files workflows."""
import argparse, os, tempfile
from pathlib import Path
from native_receiver import build_receiver, run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--only',choices=['rebase-files','changed-files','rebase-references'],action='append')
parser.add_argument('--captures',type=Path)
args=parser.parse_args();root=Path(__file__).resolve().parent.parent
cases=[('rebase-files','rebase-revision-files-native-2026-10-16.swift','PASS: native Rebase Revision Files'),('changed-files','comparison-launch-native-2026-10-14.swift','Changed Files actions:'),('rebase-references','rebase-references-native-2026-10-14.swift','Rebase references:')]
with tempfile.TemporaryDirectory(prefix='tg-rebase-files-') as temporary:
    directory=Path(temporary)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for case,source,marker in cases:
        if args.only and case not in args.only:continue
        receiver=build_receiver(root,[root/'docs/qa'/source],directory)
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture=directory/(case+str(index));fixture.mkdir();case_env=env.copy()
            if args.captures and case=='rebase-files' and index==0:case_env['TURTLEGIT_REBASE_FILES_CAPTURES']=str(args.captures.absolute())
            result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=case_env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if marker and marker not in result.stdout:raise SystemExit('Receiver exited before final assertion: '+case)
