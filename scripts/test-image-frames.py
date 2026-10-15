#!/usr/bin/env python3
"""Headless native image frame/page navigation, linked playback and retirement checks."""
from native_receiver import build_receiver, run_receiver
import argparse
import os
from pathlib import Path
import platform
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--capture-directory', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
engines = [git.resolve() for git in (args.git or [Path('/usr/bin/git')])]
for git in engines:
    if not git.is_file():
        parser.error('Git executable is missing: ' + str(git))
with tempfile.TemporaryDirectory(prefix='turtlegit-image-frames-native-') as temporary:
    directory = Path(temporary)
    executable = build_receiver(root, [root / 'docs/qa/image-frames-native-2026-10-10.swift'], directory)
    environment = os.environ.copy()
    environment['DYLD_FRAMEWORK_PATH'] = str(products)
    for index, git in enumerate(engines):
        fixture = directory / ('fixture-' + str(index)); fixture.mkdir()
        print('Checking ' + str(git), flush=True)
        command = [str(executable), str(fixture), str(git.resolve())]
        if index == 0 and args.capture_directory:
            args.capture_directory.mkdir(parents=True, exist_ok=True)
            command.append(str(args.capture_directory.resolve()))
        run_receiver(command, cwd=root, env=environment, check=True)
