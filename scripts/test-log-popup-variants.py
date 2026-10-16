#!/usr/bin/env python3
"""Grouped native Log popup variants, history actions and Find ownership."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--only',choices=['ranges','variants','history','stream','find'],action='append')
args=parser.parse_args();root=Path(__file__).resolve().parent.parent
cases=[('ranges','log-range-selection-native-2026-10-16.swift','PASS: Log filtered/labeled/Follow'),('stream','log-history-stream-native-2026-10-14.swift','Log stream:'),('variants','log-popup-variants-native-2026-10-16.swift','PASS: native Log single/root/merge'),('history','history-workflows-native-2026-10-14.swift','Log popup ownership:'),('find','log-find-native-2026-10-10.swift','PASS: Native Log Find')]
with tempfile.TemporaryDirectory(prefix='tg-log-popup-variants-') as temporary:
    directory=Path(temporary);env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for case,source,marker in cases:
        if args.only and case not in args.only:continue
        receiver=build_receiver(root,[root/'docs/qa'/source],directory)
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture=directory/(case+str(index));fixture.mkdir()
            result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if marker not in result.stdout:raise SystemExit('Receiver exited before final assertion: '+case)
