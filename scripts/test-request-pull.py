#!/usr/bin/env python3
"""Grouped owned Request Pull checks using the current Debug object/module cache."""
import argparse
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--receiver', type=Path, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
command = [sys.executable, str(root / 'scripts/test-format-patch-progress.py')]
for fixture in args.receiver or [Path('docs/qa/request-pull-native-2026-10-08.swift'), Path('docs/qa/request-pull-lifecycle-native-2026-10-15.swift')]:
    command += ['--receiver', str(fixture)]
for git in args.git or [Path('/usr/bin/git')]: command += ['--git', str(git.absolute())]
subprocess.run(command, cwd=root, check=True)
