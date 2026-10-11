#!/usr/bin/env python3
"""Check Sync history using a freshly built Debug app, private serial receivers."""
from pathlib import Path
import argparse
import ast
import os
import platform
import signal
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--revision-list', action='store_true', help='Check Sync revision columns, labels and actions instead of combo history')
parser.add_argument('--captures', type=Path, help='Optional native revision-list screenshot directory')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
objects = sorted((root / 'build/Build/Intermediates.noindex/TurtleGitMac.build/Debug/TurtleGitMac.build/Objects-normal' / platform.machine()).glob('*.o'))
if not objects or not (products / 'TurtleGitMac.swiftmodule').exists():
    raise SystemExit('Build TurtleGitMac Debug before running the native history check.')
# Reuse the lifecycle/timeout cleanup of the full native Sync driver.
driver = ast.parse((root / 'scripts/test-synchronization-dialog.py').read_text())
helper = next(n for n in driver.body if isinstance(n, ast.FunctionDef) and n.name == 'close_receiver')
scope = {'os': os, 'signal': signal, 'time': time, 'subprocess': subprocess}
exec(compile(ast.Module(body=[helper], type_ignores=[]), '<Sync receiver cleanup>', 'exec'), scope)
with tempfile.TemporaryDirectory(prefix='turtlegit-sync-history-') as temporary:
    directory = Path(temporary)
    executable = directory / 'history-receiver'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-target', platform.machine() + '-apple-macos13.0', '-I', str(products), '-F', str(products), str(root / ('docs/qa/synchronization-revision-list-native-2026-10-11.swift' if args.revision_list else 'docs/qa/synchronization-history-native-2026-10-11.swift')), *map(str, objects), '-framework', 'TurtleGitCore', '-Xlinker', '-rpath', '-Xlinker', str(products), '-Xlinker', '-e', '-Xlinker', '_turtlegit_history_main', '-o', str(executable)], check=True)
    for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture = directory / str(index)
        fixture.mkdir()
        print('Checking ' + str(git), flush=True)
        command = [str(executable), str(fixture), str(git.resolve())]
        if args.revision_list and args.captures:
            command.append(str(args.captures.resolve() / str(index)))
        receiver = subprocess.Popen(command, start_new_session=True)
        try:
            code = receiver.wait(timeout=240 if args.revision_list else 120)
            if code:
                raise subprocess.CalledProcessError(code, receiver.args)
        finally:
            scope['close_receiver'](receiver)
            print('Receiver reaped: ' + str(receiver.pid), flush=True)
