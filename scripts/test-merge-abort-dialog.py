#!/usr/bin/env python3
"""Headless native Abort Merge dialog and Cancel routing checks; no displayed prompt or signed UI acceptance."""
from native_receiver import build_receiver, run_receiver
import argparse
import os
from pathlib import Path
import platform
import signal
import time
import subprocess
import tempfile

def stop_fixture_groups(fixture):
    """Clean only process groups whose leader names this exact temporary fixture."""
    def records():
        rows = subprocess.check_output(['ps', '-axo', 'pid=,pgid=,stat=,args='], text=True).splitlines()
        return [row.split(None, 3) for row in rows if len(row.split(None, 3)) == 4]

    prefix = str(fixture) + '/'
    groups = {int(pid) for pid, group, state, command in records()
              if pid == group and not state.startswith('Z') and prefix in command}
    if not groups:
        return []

    def remaining():
        return {int(group) for _, group, state, _ in records()
                if int(group) in groups and not state.startswith('Z')}

    for action in [signal.SIGTERM, signal.SIGKILL]:
        for group in remaining():
            try:
                os.killpg(group, action)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 2
        while remaining() and time.monotonic() < deadline:
            time.sleep(0.05)
        if not remaining():
            return sorted(groups)
    raise RuntimeError('Fixture process groups did not stop: ' + str(sorted(remaining())))

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--capture-dir', type=Path)
args = parser.parse_args()
if args.capture_dir:
    args.capture_dir.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='turtlegit-merge-abort-dialog-native-') as temporary:
    directory = Path(temporary)
    executable = build_receiver(root, [root / 'docs/qa/merge-abort-dialog-native-2026-10-08.swift'], directory)
    environment = os.environ.copy()
    environment['DYLD_FRAMEWORK_PATH'] = str(products)
    for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture = directory / ('fixture-' + str(index)); fixture.mkdir()
        print('Checking ' + str(git), flush=True)
        passed = False
        try:
            run_receiver([str(executable), str(fixture), str(git.resolve()), *([str(args.capture_dir.resolve())] if args.capture_dir and index == 0 else [])], cwd=root, env=environment, check=True)
            passed = True
        finally:
            stopped = stop_fixture_groups(fixture)
            if stopped:
                print('Stopped owned fixture process groups: ' + str(stopped), flush=True)
                if passed:
                    raise RuntimeError('Receiver left fixture processes running after success')
