#!/usr/bin/env python3
"""Grouped native Rebase action controls, structural row actions and reference lifetimes."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--only',choices=['controls','row-drag','references'],action='append')
parser.add_argument('--captures',type=Path)
args=parser.parse_args();root=Path(__file__).resolve().parent.parent
cases=[('controls','rebase-action-controls-native-2026-10-16.swift','PASS: native source-ordered sticky Rebase'),('row-drag','rebase-row-drag-native-2026-10-13.swift','Rebase row drag:'),('references','rebase-references-native-2026-10-14.swift','Rebase references:')]
with tempfile.TemporaryDirectory(prefix='tg-rebase-actions-') as temporary:
    directory=Path(temporary);env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    editor=root/'build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac'
    for case,source,marker in cases:
        if args.only and case not in args.only:continue
        receiver=build_receiver(root,[root/'docs/qa'/source],directory)
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture=directory/(case+str(index));fixture.mkdir();case_env=env.copy()
            if args.captures and case=='controls' and index==0:case_env['TURTLEGIT_REBASE_ACTION_CAPTURES']=str(args.captures.absolute())
            result=run_receiver([str(receiver),str(fixture),str(git.absolute()),str(editor)],cwd=root,env=case_env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if marker not in result.stdout:raise SystemExit('Receiver exited before final assertion: '+case)
