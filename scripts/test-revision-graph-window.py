#!/usr/bin/env python3
"""Headless native Revision Graph interaction and owned-sheet lifecycle checks."""
from native_receiver import build_receiver, run_receiver
import argparse
import os
from pathlib import Path
import platform
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--capture-dir', type=Path)
parser.add_argument('--repeat', type=int, default=1, help='Sequential runs per Git engine, reusing one compiled receiver (1–10).')
args = parser.parse_args()
if not 1 <= args.repeat <= 10:
    parser.error('--repeat must be between 1 and 10.')
if args.capture_dir:
    args.capture_dir.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
engines = [git.resolve() for git in (args.git or [Path('/usr/bin/git')])]
for git in engines:
    if not git.is_file():
        parser.error('Git executable is missing: ' + str(git))
with tempfile.TemporaryDirectory(prefix='turtlegit-revision-graph-native-') as temporary:
    directory = Path(temporary)
    executable = build_receiver(root, [root / 'docs/qa/revision-graph-window-native-2026-10-10.swift'], directory)
    environment = os.environ.copy()
    environment['DYLD_FRAMEWORK_PATH'] = str(products)
    for iteration in range(args.repeat):
        for index, git in enumerate(engines):
            fixture = directory / ('fixture-' + str(iteration) + '-' + str(index)); fixture.mkdir()
            print('Checking ' + str(git) + ' (run ' + str(iteration + 1) + '/' + str(args.repeat) + ')', flush=True)
            command = [str(executable), str(fixture), str(git.resolve()), str(root / 'build/graph-layout-runtime/GraphLayout/graph-layout')]
            if iteration == 0 and index == 0 and args.capture_dir:
                command.append(str(args.capture_dir.resolve()))
            result = run_receiver(command, cwd=root, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            print(result.stdout, end='', flush=True)
            result.check_returncode()
            if 'PASS: Native Revision Graph' not in result.stdout:
                raise RuntimeError('Native receiver exited without completing its acceptance checks.')
