#!/usr/bin/env python3
"""Grouped RefLog refresh, native list, deletion and partial-failure workflows."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--only',choices=['lifecycle','table','deletion','partial'],action='append')
args=parser.parse_args();root=Path(__file__).resolve().parent.parent
cases=[('lifecycle','reflog-lifecycle-native-2026-10-16.swift','PASS: RefLog missing-ref'),('table','reflog-table-native-2026-10-13.swift','RefLog native table:'),('deletion','reflog-deletion-native-2026-10-08.swift','RefLog deletion: source'),('partial','reflog-partial-failure-native-2026-10-08.swift','RefLog partial failure: real')]
with tempfile.TemporaryDirectory(prefix='tg-reflog-lifecycle-') as temporary:
    directory=Path(temporary);env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for case,source,marker in cases:
        if args.only and case not in args.only:continue
        receiver=build_receiver(root,[root/'docs/qa'/source],directory)
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture=directory/(case+str(index));fixture.mkdir()
            result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if marker not in result.stdout:raise SystemExit('Receiver exited before final assertion: '+case)
