#!/usr/bin/env python3
"""Grouped Settings navigation/layout, color controls and cached-page regressions."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--capture-dir',type=Path)
parser.add_argument('--only',choices=['layout','colors','family'],action='append')
args=parser.parse_args();root=Path(__file__).resolve().parent.parent
cases=[('layout',['docs/qa/settings-navigation-layout-native-2026-10-16.swift'],'PASS: recursive nested Settings'),('colors',['docs/qa/settings-color-choices-native-2026-10-16.swift','docs/qa/merge-colors-native-2026-10-12.swift'],'PASS: connected Settings color controls'),('family',['docs/qa/settings-family-native-2026-10-13.swift'],'Settings family')]
with tempfile.TemporaryDirectory(prefix='tg-settings-layout-') as temporary:
    folder=Path(temporary)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for name,sources,passing in cases:
        if args.only and name not in args.only:continue
        build=folder/name;build.mkdir();receiver=build_receiver(root,[root/source for source in sources],build)
        if args.capture_dir:
            env['TURTLEGIT_SETTINGS_LAYOUT_CAPTURES']=str(args.capture_dir.resolve())
            env['TURTLEGIT_SETTINGS_COLOR_CAPTURES']=str(args.capture_dir.resolve())
        engines=(args.git or [Path('/usr/bin/git')]) if name=='family' else [Path('/usr/bin/git')]
        for index,git in enumerate(engines):
            fixture=build/str(index);fixture.mkdir()
            result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if passing not in result.stdout:raise SystemExit('Receiver exited before final assertion: '+name)
