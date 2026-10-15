#!/usr/bin/env python3
"""Hidden native Log palette/settings and existing table Apply checks on private repos."""
from native_receiver import build_receiver, run_receiver
import argparse
import os
from pathlib import Path
import platform
import subprocess
import tempfile
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='turtlegit-log-palette-native-') as temporary:
    directory = Path(temporary)
    executable = build_receiver(root, [root / 'docs/qa/log-palette-native-2026-10-09.swift'], directory)
    environment = os.environ.copy(); environment['DYLD_FRAMEWORK_PATH'] = str(products)
    for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture = directory/('fixture-'+str(index)); fixture.mkdir()
        print('Checking '+str(git.resolve()),flush=True)
        run_receiver([str(executable),str(fixture),str(git.resolve())],cwd=root,env=environment,check=True)
