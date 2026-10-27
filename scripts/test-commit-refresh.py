#!/usr/bin/env python3
"""Headless native Commit refresh cancellation and close fencing checks. No displayed UI or signed acceptance."""
from native_receiver import build_receiver, run_receiver
import argparse
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import signal
import sys
import time

def retire_captured_read_helper(fixture):
    """Timeout backstop for the one authored helper's separate Git process group.

    A stale marker alone is never ownership. Both exact wrapper argv and its
    open private resource must match before either signal, including escalation.
    """
    private = fixture / '.git/captured-read-fixture/.git'
    marker, wrapper, resource = private / 'diff.pid', private / 'count-git', private / 'owned-diff-resource'
    try:
        text = marker.read_text().strip()
        if not text.isascii() or not text.isdecimal():
            raise RuntimeError('Invalid private captured-read helper PID')
        pid = int(text)
        if pid <= 1:
            raise RuntimeError('Invalid private captured-read helper PID')
    except FileNotFoundError:
        return

    def alive():
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False

    def owned():
        if not alive():
            return False
        command = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'command='],
                                 capture_output=True, text=True, timeout=5, check=False)
        argv = command.stdout.strip()
        names = {str(wrapper.absolute()), str(wrapper.resolve())}
        if not any(argv == '/bin/sh ' + name or argv.startswith('/bin/sh ' + name + ' ') for name in names):
            return False
        opened = subprocess.run(['/usr/sbin/lsof', '-a', '-p', str(pid), '-Fn'],
                                capture_output=True, text=True, timeout=5, check=False)
        return opened.returncode == 0 and 'n' + str(resource.resolve()) in opened.stdout.splitlines()

    # A recycled PID with another argv/resource is unrelated and remains alone.
    if not owned():
        return
    for number in (signal.SIGTERM, signal.SIGKILL):
        if not alive():
            return
        if not owned():
            raise RuntimeError('Captured-read helper ownership changed before cleanup')
        try:
            group = os.getpgid(pid)
            os.killpg(group, number) if group == pid else os.kill(pid, number)
        except ProcessLookupError:
            return
        deadline = time.monotonic() + 3
        while alive() and time.monotonic() < deadline:
            time.sleep(.03)
        if not alive():
            return
    raise RuntimeError('Verified owned captured-read helper survived cleanup')


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
engines = [git.resolve() for git in (args.git or [Path('/usr/bin/git')])]
for git in engines:
    if not git.is_file():
        parser.error('Git executable is missing: ' + str(git))
with tempfile.TemporaryDirectory(prefix='turtlegit-commit-refresh-native-') as temporary:
    directory = Path(temporary)
    executable = build_receiver(root, [root / 'docs/qa/commit-refresh-native-2026-10-10.swift'], directory)
    environment = os.environ.copy()
    environment['DYLD_FRAMEWORK_PATH'] = str(products)
    for index, git in enumerate(engines):
        fixture = directory / ('fixture-' + str(index)); fixture.mkdir()
        print('Checking ' + str(git), flush=True)
        original_error = None
        try:
            run_receiver([str(executable), str(fixture), str(git.resolve())], cwd=root, env=environment, check=True)
        except BaseException as error:
            original_error = error
            raise
        finally:
            try:
                retire_captured_read_helper(fixture)
            except Exception as cleanup_error:
                if original_error is None:
                    raise
                print('Captured-read timeout cleanup failed: ' + str(cleanup_error), file=sys.stderr)
