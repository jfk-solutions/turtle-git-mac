#!/usr/bin/env python3
"""Grouped native Clone/Create source navigation, forms, bare setup and owner lifetime."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--git',type=Path,action='append')
p.add_argument('--only',choices=['navigation','forms','creation','ownership','accessibility'],action='append')
p.add_argument('--captures',type=Path)
a=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-clone-create-') as temporary:
    directory=Path(temporary);receiver=build_receiver(root,[root/'docs/qa/clone-create-source-native-2026-10-21.swift'],directory)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    if a.captures:a.captures.mkdir(parents=True,exist_ok=True);env['TURTLEGIT_CLONE_CREATE_CAPTURES']=str(a.captures.absolute())
    for case in a.only or ['navigation','forms','creation','ownership']:
        for index,git in enumerate(a.git or [Path('/usr/bin/git')]):
            directory_case=directory/(case+str(index));directory_case.mkdir()
            result=run_receiver([str(receiver),str(directory_case),str(git.absolute()),case],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: Clone/Create '+case not in result.stdout:raise SystemExit('Receiver exited before final assertions: '+case)
