#!/usr/bin/env python3
"""Grouped Finder clipboard handoff and native patch-source chooser workflows."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--git',type=Path,action='append');a=p.parse_args()
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='TurtleGitClipboardEntry-') as temporary:
    directory=Path(temporary)
    receiver=build_receiver(root,[root/'FinderSync/FinderSync.swift',root/'docs/qa/clipboard-patch-entry-native-2026-10-17.swift'],directory)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for index,git in enumerate(a.git or [Path('/usr/bin/git')]):
        fixture=directory/str(index);fixture.mkdir()
        result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
        print(result.stdout,end='',flush=True);print(result.stderr,end='',flush=True);result.check_returncode()
        if 'PASS: clipboard patch entry family' not in result.stdout:raise SystemExit('Missing completion marker')
