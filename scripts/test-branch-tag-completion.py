#!/usr/bin/env python3
"""Grouped Branch/Tag creation completion, cancellation and retained handoffs."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--only',choices=['completion','handoff','pickers'],action='append')
args=parser.parse_args();root=Path(__file__).resolve().parent.parent
cases=[('completion','branch-tag-completion-native-2026-10-16.swift','PASS: Branch/Tag completion'),('handoff','branch-tag-handoff-native-2026-10-08.swift','Branch/Tag:'),('pickers','creation-pickers-native-2026-10-09.swift','PASS: actual Branch/Tag/Worktree')]
with tempfile.TemporaryDirectory(prefix='turtlegit-branch-tag-completion-') as temporary:
    directory=Path(temporary);env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for case,source,marker in cases:
        if args.only and case not in args.only:continue
        receiver=build_receiver(root,[root/'docs/qa'/source],directory)
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture=directory/(case+str(index));fixture.mkdir()
            result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if marker not in result.stdout:raise SystemExit('Receiver exited before final assertion: '+case)
