#!/usr/bin/env python3
"""Grouped native source Log keyboard, message-menu and ownership checks."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-log-source-') as temporary:
    directory = Path(temporary)
    receiver = build_receiver(root, [root/'docs/qa/log-source-commands-native-2026-10-18.swift'], directory)
    environment = os.environ.copy()
    environment.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture = directory/str(index); fixture.mkdir()
        print('Checking Log source commands with '+str(git), flush=True)
        result = run_receiver([str(receiver), str(fixture), str(git.resolve())], cwd=root, env=environment, capture_output=True, text=True)
        print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
        if 'PASS: Log source focus/find/refresh/escape/copy' not in result.stdout:
            raise SystemExit('Log source command receiver exited before completion.')
