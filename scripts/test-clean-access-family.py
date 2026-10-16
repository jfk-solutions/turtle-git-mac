#!/usr/bin/env python3
"""Grouped Clean metadata authorization, ownership, progress policy and cleanup actions."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
cases=[('metadata','clean-metadata-access-native-2026-10-17.swift','PASS Clean metadata:'),('ownership','clean-owned-access-native-2026-10-14.swift','PASS: Clean options'),('policy','clean-progress-policy-native-2026-10-08.swift','Clean policy:'),('actions','clean-native-receiver-2026-10-07.swift','Native Clean:')]
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--git',type=Path,action='append');parser.add_argument('--only',choices=[case[0] for case in cases],action='append');args=parser.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-clean-access-') as temporary:
    directory=Path(temporary);env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for name,source,marker in cases:
        if args.only and name not in args.only:continue
        receiver=build_receiver(root,[root/'docs/qa'/source],directory)
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture=directory/(name+str(index));fixture.mkdir();print('Checking Clean '+name+' with '+str(git),flush=True)
            result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if marker not in result.stdout:raise SystemExit('Receiver did not finish assertions: '+name)
