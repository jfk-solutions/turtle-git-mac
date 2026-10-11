#!/usr/bin/env python3
"""Headless native reference-browser reference deletion handoff checks. No displayed UI or signed acceptance."""
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
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='turtlegit-reference-delete-native-') as temporary:
    directory = Path(temporary)
    objects = sorted((root / 'build/Build/Intermediates.noindex/TurtleGitMac.build/Debug/TurtleGitMac.build/Objects-normal' / platform.machine()).glob('*.o'))
    if not objects or not (products / 'TurtleGitMac.swiftmodule').exists():
        raise SystemExit('Build TurtleGitMac Debug before running the native deletion check.')
    source = directory / 'reference-delete.swift'
    fixture_source = (root / 'docs/qa/reference-delete-native-2026-10-09.swift').read_text().replace('@main struct', 'struct', 1)
    source.write_text('@testable import TurtleGitMac\n' + fixture_source + """
@_cdecl("turtlegit_reference_delete_main") func bootstrap() -> Int32 {
    Task { @MainActor in
        await ReferenceDeleteVerification.main()
        exit(0)
    }
    NSApplication.shared.run(); return 0
}
""")
    executable = directory / 'reference-delete-native-receiver'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-target', platform.machine() + '-apple-macos13.0', '-I', str(products), '-F', str(products), str(source), *map(str, objects), '-framework', 'TurtleGitCore', '-Xlinker', '-rpath', '-Xlinker', str(products), '-Xlinker', '-e', '-Xlinker', '_turtlegit_reference_delete_main', '-o', str(executable)], cwd=root, check=True)
    # Share the bounded owned-process-group cleanup used by the Sync driver.
    driver = ast.parse((root / 'scripts/test-synchronization-dialog.py').read_text())
    helper = next(n for n in driver.body if isinstance(n, ast.FunctionDef) and n.name == 'close_receiver')
    cleanup = {'os': os, 'signal': signal, 'time': time, 'subprocess': subprocess}
    exec(compile(ast.Module(body=[helper], type_ignores=[]), '<native receiver cleanup>', 'exec'), cleanup)
    environment = os.environ.copy()
    environment['DYLD_FRAMEWORK_PATH'] = str(products)
    for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture = directory / ('fixture-' + str(index)); fixture.mkdir()
        print('Checking ' + str(git), flush=True)
        command = [str(executable), str(fixture), str(git.resolve())]
        receiver = subprocess.Popen(command, cwd=root, env=environment, start_new_session=True)
        try:
            code = receiver.wait(timeout=300)
            if code:
                raise subprocess.CalledProcessError(code, command)
        finally:
            cleanup['close_receiver'](receiver)
            print('Receiver reaped: ' + str(receiver.pid), flush=True)
