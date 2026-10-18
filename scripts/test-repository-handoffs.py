#!/usr/bin/env python3
"""Grouped workspace handoffs after Clone/Init and competing native owners."""
import argparse, os, tempfile
from pathlib import Path
from native_receiver import build_receiver, run_receiver
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--git',type=Path,action='append')
args=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-repository-handoffs-') as temporary:
    folder=Path(temporary)
    receiver=build_receiver(root,[root/'docs/qa/repository-handoffs-native-2026-10-18.swift'],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
        directory=folder/str(index);directory.mkdir()
        print('Checking repository handoffs with '+str(git),flush=True)
        result=run_receiver([str(receiver),str(directory),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if 'PASS: repository handoff family:' not in result.stdout:raise SystemExit('Native repository handoff checks did not finish')
