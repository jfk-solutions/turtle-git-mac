#!/usr/bin/env python3
"""Verify source-style native Log filter fields against current Debug objects."""
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
if args.captures:
    args.captures = args.captures.absolute()
    args.captures.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='TurtleGitLogFilters-') as temporary:
    directory = Path(temporary)
    executable = build_receiver(root, [root / 'docs/qa/log-filters-native-2026-10-15.swift'], directory)
    environment = os.environ.copy()
    environment.update(DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
    for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture = directory / str(index) / 'Harbor'; fixture.mkdir(parents=True)
        print('Checking native Log filters with ' + str(git), flush=True)
        result = run_receiver([str(executable), str(fixture), str(git.absolute()), *([str(args.captures)] if args.captures and index == 0 else [])], cwd=root, env=environment, capture_output=True, text=True)
        print(result.stdout, end=''); print(result.stderr, end='')
        result.check_returncode()
        if 'PASS: Log filters completed:' not in result.stdout:
            raise SystemExit('Native Log filter receiver exited without its completion marker.')
