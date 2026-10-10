#!/usr/bin/env python3
"""Headless native Synchronization workflow checks; no displayed prompt or signed UI acceptance."""
import argparse
import os
from pathlib import Path
import platform
import signal
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='turtlegit-sync-native-') as temporary:
    directory = Path(temporary)
    app = root / 'Sources/TurtleGitMac/TurtleGitMacApp.swift'
    copy = directory / app.name
    copy.write_text(app.read_text().replace('@main struct', 'struct', 1))
    sources = sorted(str(p) for p in (root / 'Sources/TurtleGitMac').glob('*.swift') if p != app)
    executable = directory / 'sync-native-receiver'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-target', platform.machine() + '-apple-macos13.0', '-I', str(products), '-F', str(products), *sources, str(copy), str(root / 'docs/qa/synchronization-native-2026-10-11.swift'), '-framework', 'TurtleGitCore', '-o', str(executable)], cwd=root, check=True)
    environment = os.environ.copy()
    environment['DYLD_FRAMEWORK_PATH'] = str(products)
    for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture = directory / ('fixture-' + str(index)); fixture.mkdir()
        print('Checking ' + str(git), flush=True)
        receiver = subprocess.Popen([str(executable), str(fixture), str(git.resolve())], cwd=root, env=environment, start_new_session=True)
        try:
            code = receiver.wait(timeout=120)
            if code:
                raise subprocess.CalledProcessError(code, receiver.args)
        finally:
            try:
                os.killpg(receiver.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                try:
                    os.killpg(receiver.pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.05)
            else:
                try:
                    os.killpg(receiver.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            receiver.wait()
