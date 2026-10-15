#!/usr/bin/env python3
"""Check source history limits in owned hidden native windows and private repositories."""
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
git_paths = args.git or [Path('/usr/bin/git')]
for git in git_paths:
    if not git.is_file():
        parser.error('Git executable does not exist: ' + str(git))
with tempfile.TemporaryDirectory(prefix='turtlegit-history-limits-native-') as temporary:
    directory = Path(temporary)
    executable = build_receiver(root, [root / 'docs/qa/log-history-limits-native-2026-10-09.swift'], directory)
    environment = os.environ.copy()
    environment['DYLD_FRAMEWORK_PATH'] = str(products)
    for index, git in enumerate(git_paths):
        fixture = directory / ('fixture-' + str(index)); fixture.mkdir()
        print('Checking ' + str(git), flush=True)
        run_receiver([str(executable), str(fixture), str(git.resolve())], cwd=root, env=environment, check=True)
