#!/usr/bin/env python3
"""Grouped complete Commit reads, staging, editor metadata, templates, providers and native list restoration."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
cases=[('snapshot','commit-refresh-snapshot-native-2026-10-17.swift','PASS Commit refresh snapshot:'),('staging','commit-staging-list-native-2026-10-16.swift','PASS: Commit incremental staging'),('metadata','commit-metadata-native-2026-10-09.swift','PASS: actual hidden Commit metadata'),('preferences','commit-preferences-native-2026-10-13.swift','Commit templates:'),('provider','native-issue-provider-native-2026-10-14.swift','PASS native issue providers:'),('position','file-list-refresh-native-2026-10-16.swift','PASS file-list refresh:')]
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--git',type=Path,action='append');parser.add_argument('--only',choices=[case[0] for case in cases],action='append');args=parser.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-commit-refresh-') as temporary:
    folder=Path(temporary);env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for name,source,marker in cases:
        if args.only and name not in args.only:continue
        receiver=build_receiver(root,[root/'docs/qa'/source],folder)
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture=folder/(name+str(index));fixture.mkdir();print('Checking Commit refresh '+name+' with '+str(git),flush=True)
            result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if marker not in result.stdout:raise SystemExit('Receiver did not finish assertions: '+name)
