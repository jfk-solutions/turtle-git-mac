#!/usr/bin/env python3
"""Grouped primary command startup, permissions, presets and native dialogs."""
import argparse, os, tempfile
from pathlib import Path
from native_receiver import build_receiver, run_receiver
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--git',type=Path,action='append')
p.add_argument('--only',choices=['family','bare','io','network','files'],action='append')
args=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-primary-commands-') as temporary:
    folder=Path(temporary)
    receiver=build_receiver(root,[root/'docs/qa/primary-commands-native-2026-10-18.swift',root/'docs/qa/source-file-commands-native-2026-10-18.swift'],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for case in args.only or ['family','bare','io','network','files']:
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            directory=folder/(case+str(index));directory.mkdir()
            print('Checking primary command '+case+' with '+str(git),flush=True)
            result=run_receiver([str(receiver),str(directory),str(git.absolute()),case],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            marker={'family':'PASS: once-only startup','io':'PASS: command file IO family','bare':'PASS: bare command eligibility','network':'PASS: network/reference command family','files':'PASS: source file command family'}[case]
            if marker not in result.stdout:raise SystemExit('Native primary command checks did not finish')
