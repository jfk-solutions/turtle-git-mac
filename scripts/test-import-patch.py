#!/usr/bin/env python3
"""Headless native Import Patch workflow checks. No displayed UI or signed acceptance."""
import argparse
import os
import signal
import time
from pathlib import Path
import platform
import subprocess
import tempfile

def close_receiver(receiver):
    """Stop this owned group and reap its leader before probing descendants."""
    try:
        os.killpg(receiver.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        receiver.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(receiver.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        receiver.wait()
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            os.killpg(receiver.pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.05)
    try:
        os.killpg(receiver.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--lifecycle-only', action='store_true')
parser.add_argument('--git', type=Path, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='turtlegit-import-patch-native-') as temporary:
    directory = Path(temporary)
    app = root / 'Sources/TurtleGitMac/TurtleGitMacApp.swift'
    copy = directory / app.name
    copy.write_text(app.read_text().replace('@main struct', 'struct', 1))
    sources = sorted(str(p) for p in (root / 'Sources/TurtleGitMac').glob('*.swift') if p != app)
    executable = directory / 'import-patch-native-receiver'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-target', platform.machine() + '-apple-macos13.0', '-I', str(products), '-F', str(products), *sources, str(copy), str(root / 'docs/qa/import-patch-native-2026-10-08.swift'), str(root / 'docs/qa/import-patch-lifecycle-native-2026-10-11.swift'), '-framework', 'TurtleGitCore', '-o', str(executable)], cwd=root, check=True)
    environment = os.environ.copy()
    if args.lifecycle_only: environment['TURTLEGIT_IMPORT_LIFECYCLE_ONLY'] = '1'
    environment['DYLD_FRAMEWORK_PATH'] = str(products)
    for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture = directory / ('fixture-' + str(index)); fixture.mkdir()
        print('Checking ' + str(git), flush=True)
        receiver = subprocess.Popen([str(executable), str(fixture), str(git.resolve())], cwd=root, env=environment, start_new_session=True)
        try:
            code = receiver.wait(timeout=600)
            if code: raise subprocess.CalledProcessError(code, receiver.args)
        finally:
            close_receiver(receiver)
