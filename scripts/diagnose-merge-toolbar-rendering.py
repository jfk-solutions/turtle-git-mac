#!/usr/bin/env python3
"""Collect owned AppKit toolbar pixel/control/rendering diagnostics, not a parity pass."""
import argparse
import os
from pathlib import Path
import shutil
import tempfile
from native_receiver import build_receiver,run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output',type=Path,default=Path('build/qa/toolbar-rendering-diagnostic'))
args=parser.parse_args();root=Path(__file__).resolve().parent.parent
args.output.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='turtlegit-toolbar-rendering-') as temporary:
    folder=Path(temporary);helper=folder/'TwoPane.swift'
    helper.write_text((root/'docs/qa/two-pane-engine-native-2026-10-12.swift').read_text().replace('@main ', '',1))
    receiver=build_receiver(root,[helper,root/'docs/qa/merge-toolbar-rendering-diagnostic-2026-10-16.swift'],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1')
    result=run_receiver([str(receiver),str(folder)],cwd=root,env=env,capture_output=True,text=True)
    print(result.stdout,end='');print(result.stderr,end='')
    for capture in folder.glob('*.png'):shutil.copyfile(capture,args.output/capture.name)
    result.check_returncode()
    if 'PASS: owned toolbar rendering diagnostic completed' not in result.stdout:raise SystemExit('Toolbar diagnostic exited before collecting its data.')
