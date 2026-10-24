#!/usr/bin/env python3
"""Grouped four-pane P4Merge presentation, selection/history and save acceptance."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver,run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--capture',type=Path)
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
sources=root/'build/qa/p4merge-layout-native-sources';sources.mkdir(parents=True,exist_ok=True)
receiver=build_receiver(root,[root/'docs/qa/merge-conflict-inspection-native-2026-10-20.swift',root/'docs/qa/p4merge-layout-native-2026-10-24.swift'],sources)
with tempfile.TemporaryDirectory(prefix='TurtleGit-P4Merge-') as temporary:
    folder=Path(temporary);private=folder/'temporary';private.mkdir(mode=0o700)
    env=dict(os.environ,TMPDIR=str(private)+'/',GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',XDG_CONFIG_HOME=str(folder/'xdg'))
    for key in ['GIT_CONFIG_PARAMETERS','GIT_AUTHOR_NAME','GIT_AUTHOR_EMAIL','GIT_AUTHOR_DATE','GIT_COMMITTER_NAME','GIT_COMMITTER_EMAIL','GIT_COMMITTER_DATE']:env.pop(key,None)
    command=[str(receiver),str(folder)]
    if args.capture:command.append(str(args.capture.absolute()))
    result=run_receiver(command,cwd=root,env=env,capture_output=True,text=True,timeout_sample=folder/'timeout.sample.txt')
    print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
    if 'PASS P4Merge layout:' not in result.stdout:raise SystemExit('Receiver exited before completion')
