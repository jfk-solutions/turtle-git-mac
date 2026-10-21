#!/usr/bin/env python3
"""Headless native Statistics models/windows. Does not verify displayed or signed UI."""
from native_receiver import build_receiver, run_receiver
import argparse
import os
from pathlib import Path
import platform
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--captures', type=Path)
parser.add_argument('--only', choices=['family', 'summary', 'workflow'], default='family')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='turtlegit-statistics-native-') as temporary:
    directory = Path(temporary)
    executable = build_receiver(root, [root / 'docs/qa/statistics-native-receiver-2026-10-07.swift', root / 'docs/qa/statistics-source-native-2026-10-17.swift'], directory)
    environment = os.environ.copy()
    environment['DYLD_FRAMEWORK_PATH'] = str(products)
    environment['TURTLEGIT_STATISTICS_CASE'] = args.only
    for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture = directory / ('fixture-' + str(index)); fixture.mkdir()
        environment.pop('TURTLEGIT_STATISTICS_SOURCE_CAPTURE', None)
        if args.captures and index == 0:
            environment['TURTLEGIT_STATISTICS_SOURCE_CAPTURE'] = str(args.captures.resolve())
        print('Checking ' + str(git), flush=True)
        run_receiver([str(executable), str(fixture), str(git.resolve())], cwd=root, env=environment, check=True)
