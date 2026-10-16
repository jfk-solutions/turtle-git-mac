#!/usr/bin/env python3
"""Grouped primary file-menu workflows using current cached Debug app objects."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--only',choices=['primary-file-menus-2026-10-16','working-tree-file-menu','working-tree-scope'],action='append')
args=parser.parse_args();root=Path(__file__).resolve().parent.parent
cases=[('primary-file-menus-2026-10-16','docs/qa/primary-file-menus-native-2026-10-16.swift','PASS: primary marked-row'),('working-tree-file-menu','docs/qa/working-tree-file-menu-native-2026-10-14.swift','Working Tree menus:'),('working-tree-scope','docs/qa/working-tree-scope-native-2026-10-14.swift','Working Tree scope')]
with tempfile.TemporaryDirectory(prefix='tg-primary-menus-') as temporary:
    folder=Path(temporary)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for name,source,passing in cases:
        if args.only and name not in args.only:continue
        build=folder/name;build.mkdir();receiver=build_receiver(root,[root/source],build)
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture=build/str(index);fixture.mkdir()
            result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if passing not in result.stdout:raise SystemExit('Receiver exited before final assertion: '+name)
