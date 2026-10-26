#!/usr/bin/env python3
"""Grouped Commit staging activation, partial pane and saved preference workflows."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--only',choices=['list','mode','partial','preferences','checkbox','progress','refresh'],action='append')
args=parser.parse_args();root=Path(__file__).resolve().parent.parent
cases=[('refresh','commit-refresh-native-2026-10-26.swift','PASS: Commit refresh scoped','commit-refresh'),('checkbox','commit-checkbox-index-native-2026-10-16.swift','PASS: actual Commit checkbox index','commit-checkbox-index'),('progress','commit-progress-native-2026-10-08.swift','Commit progress:','commit-progress'),('list','commit-staging-list-native-2026-10-16.swift','PASS: Commit incremental staging','commit-staging-list'),('mode','commit-staging-mode-native-2026-10-16.swift','PASS: Commit mode/preview','commit-staging-mode'),('partial','partial-patch-native-2026-10-13.swift','Partial patch:','partial-patch'),('preferences','commit-preferences-native-2026-10-13.swift','Commit preferences:','commit-preferences')]
with tempfile.TemporaryDirectory(prefix='tg-commit-staging-mode-') as temporary:
    directory=Path(temporary);env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for case,source,marker,legacy in cases:
        if args.only and case not in args.only:continue
        receiver=build_receiver(root,[root/'docs/qa'/source],directory)
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture=directory/(case+str(index));fixture.mkdir()
            result=run_receiver([str(receiver),str(fixture),str(git.absolute()),legacy],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if marker not in result.stdout:raise SystemExit('Receiver exited before final assertion: '+case)
