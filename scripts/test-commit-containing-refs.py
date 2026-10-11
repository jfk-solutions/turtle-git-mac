#!/usr/bin/env python3
"""Headless native commit-containing references interaction and owned-sheet lifecycle checks."""
import argparse
import ast
import os
import signal
import time
from pathlib import Path
import platform
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--capture-dir', type=Path)
args = parser.parse_args()
if args.capture_dir:
    args.capture_dir.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
engines = [git.resolve() for git in (args.git or [Path('/usr/bin/git')])]
for git in engines:
    if not git.is_file():
        parser.error('Git executable is missing: ' + str(git))
with tempfile.TemporaryDirectory(prefix='turtlegit-commit-refs-native-') as temporary:
    directory = Path(temporary)
    objects = sorted((root / 'build/Build/Intermediates.noindex/TurtleGitMac.build/Debug/TurtleGitMac.build/Objects-normal' / platform.machine()).glob('*.o'))
    if not objects or not (products / 'TurtleGitMac.swiftmodule').exists():
        raise SystemExit('Build TurtleGitMac Debug before running the native references check.')
    source = directory / 'commit-refs.swift'
    fixture_source = (root / 'docs/qa/commit-containing-refs-native-2026-10-10.swift').read_text().replace('@main struct', 'struct', 1)
    source.write_text('@testable import TurtleGitMac\n' + fixture_source + """
@_cdecl("turtlegit_commit_refs_main") func bootstrap() -> Int32 {
    MainActor.assumeIsolated { CommitReferencesVerification.main() }
    return 0
}
""")
    executable = directory / 'commit-refs-native-receiver'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-target', platform.machine() + '-apple-macos13.0', '-I', str(products), '-F', str(products), str(source), *map(str, objects), '-framework', 'TurtleGitCore', '-Xlinker', '-rpath', '-Xlinker', str(products), '-Xlinker', '-e', '-Xlinker', '_turtlegit_commit_refs_main', '-o', str(executable)], cwd=root, check=True)
    driver = ast.parse((root / 'scripts/test-synchronization-dialog.py').read_text())
    helper = next(n for n in driver.body if isinstance(n, ast.FunctionDef) and n.name == 'close_receiver')
    cleanup = {'os': os, 'signal': signal, 'time': time, 'subprocess': subprocess}
    exec(compile(ast.Module(body=[helper], type_ignores=[]), '<native receiver cleanup>', 'exec'), cleanup)
    environment = os.environ.copy()
    environment['DYLD_FRAMEWORK_PATH'] = str(products)
    for index, git in enumerate(engines):
        fixture = directory / ('fixture-' + str(index)); fixture.mkdir()
        print('Checking ' + str(git), flush=True)
        command = [str(executable), str(fixture), str(git.resolve())]
        if index == 0 and args.capture_dir:
            command.append(str(args.capture_dir.resolve()))
        receiver = subprocess.Popen(command, cwd=root, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
        try:
            stdout, _ = receiver.communicate(timeout=300)
            print(stdout, end='', flush=True)
            if receiver.returncode:
                raise subprocess.CalledProcessError(receiver.returncode, command)
            if 'PASS: Native commit-containing references' not in stdout:
                raise RuntimeError('Native receiver exited without completing its acceptance checks.')
        finally:
            cleanup['close_receiver'](receiver)
            print('Receiver reaped: ' + str(receiver.pid), flush=True)
