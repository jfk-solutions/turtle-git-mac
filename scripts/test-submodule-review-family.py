#!/usr/bin/env python3
"""Grouped native submodule comparison and conflict actions, routing and lifetimes."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--git',type=Path,action='append')
p.add_argument('--only',choices=['actions','diff-ownership','routing','conflict-ownership'],action='append')
p.add_argument('--captures',type=Path)
a=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-submodule-review-') as temporary:
    directory=Path(temporary);receiver=build_receiver(root,[root/'docs/qa/submodule-review-family-native-2026-10-21.swift'],directory)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    if a.captures:a.captures.mkdir(parents=True,exist_ok=True);env['TURTLEGIT_SUBMODULE_REVIEW_CAPTURES']=str(a.captures.absolute())
    for case in a.only or ['actions','diff-ownership','routing','conflict-ownership']:
        for index,git in enumerate(a.git or [Path('/usr/bin/git')]):
            folder=directory/(case+str(index));folder.mkdir()
            result=run_receiver([str(receiver),str(folder),str(git.absolute()),case],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: submodule review '+case not in result.stdout:raise SystemExit('Receiver exited before final assertion: '+case)
