#!/usr/bin/env python3
"""Grouped native Commit/Working Tree changelist identity and cleanup workflows."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--captures', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-changelist-family-') as temporary:
    directory = Path(temporary)
    receiver = build_receiver(root, [root/'docs/qa/changelist-identities-native-2026-10-17.swift'], directory)
    env = os.environ.copy()
    env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture = directory/str(index); fixture.mkdir()
        env.pop('TURTLEGIT_CHANGELIST_CAPTURE', None)
        if args.captures and index == 0:
            env['TURTLEGIT_CHANGELIST_CAPTURE'] = str(args.captures.resolve())
        print('Checking changelist family '+str(git), flush=True)
        result = run_receiver([str(receiver), str(fixture), str(git.resolve())], cwd=root, env=env, capture_output=True, text=True)
        print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
        if 'PASS: byte-distinct changelist names' not in result.stdout:
            raise SystemExit('Changelist receiver exited before completing its workflow.')
