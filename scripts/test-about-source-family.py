#!/usr/bin/env python3
"""Native About variants, selected Git reads, banner lifetime and captured routes."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append');parser.add_argument('--captures',type=Path)
args=parser.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-about-source-') as temporary:
    folder=Path(temporary);receiver=build_receiver(root,[root/'docs/qa/about-source-native-2026-10-17.swift'],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture=folder/str(index);fixture.mkdir();env.pop('TURTLEGIT_ABOUT_SOURCE_CAPTURE',None)
        for name in ['home','preferences','xdg','temporary']:(fixture/name).mkdir(mode=0o700)
        env={k:v for k,v in env.items() if not k.startswith('GIT_')}
        env.update(HOME=str(fixture/'home'),CFFIXED_USER_HOME=str(fixture/'preferences'),XDG_CONFIG_HOME=str(fixture/'xdg'),TMPDIR=str(fixture/'temporary')+'/',GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
        if args.captures and index==0:
            args.captures.mkdir(parents=True,exist_ok=True);env['TURTLEGIT_ABOUT_SOURCE_CAPTURE']=str(args.captures.absolute())
        print('Checking About family with '+str(git),flush=True)
        result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if 'PASS: About source family' not in result.stdout:raise SystemExit('About receiver exited before completion.')
