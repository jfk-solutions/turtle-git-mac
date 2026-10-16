#!/usr/bin/env python3
"""Headless native remote tag dialog and folder routes. No displayed UI or signed acceptance."""
from native_receiver import build_receiver, run_receiver
import argparse
import os
from pathlib import Path
import platform
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['tags', 'owned'], action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='turtlegit-remote-tags-native-') as temporary:
    directory = Path(temporary)
    environment = os.environ.copy()
    environment.update(DYLD_FRAMEWORK_PATH=str(products), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for case, source, marker in [('tags', 'remote-tags-native-2026-10-09.swift', 'PASS remote tag source folder'), ('owned', 'remote-management-owned-native-2026-10-16.swift', 'PASS: remote tag error/reload ordering')]:
        if args.only and case not in args.only: continue
        executable = build_receiver(root, [root / 'docs/qa' / source], directory)
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture = directory / (case + str(index)); fixture.mkdir()
            print('Checking ' + case + ' with ' + str(git), flush=True)
            result = run_receiver([str(executable), str(fixture), str(git.resolve())], cwd=root, env=environment, capture_output=True, text=True)
            print(result.stdout, end='', flush=True); print(result.stderr, end='', flush=True); result.check_returncode()
            if marker not in result.stdout: raise SystemExit('Missing final assertion: ' + case)
