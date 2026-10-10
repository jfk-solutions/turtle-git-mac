#!/usr/bin/env python3
"""Headless native Abort Merge dialog and Cancel routing checks; no displayed prompt or signed UI acceptance."""
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
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='turtlegit-merge-abort-dialog-native-') as temporary:
    directory = Path(temporary)
    app = root / 'Sources/TurtleGitMac/TurtleGitMacApp.swift'
    copy = directory / app.name
    copy.write_text(app.read_text().replace('@main struct', 'struct', 1))
    sources = sorted(str(p) for p in (root / 'Sources/TurtleGitMac').glob('*.swift') if p != app)
    executable = directory / 'merge-abort-dialog-native-receiver'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-target', platform.machine() + '-apple-macos13.0', '-I', str(products), '-F', str(products), *sources, str(copy), str(root / 'docs/qa/merge-abort-dialog-native-2026-10-08.swift'), '-framework', 'TurtleGitCore', '-o', str(executable)], cwd=root, check=True)
    environment = os.environ.copy()
    environment['DYLD_FRAMEWORK_PATH'] = str(products)
    for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture = directory / ('fixture-' + str(index)); fixture.mkdir()
        print('Checking ' + str(git), flush=True)
        passed = False
        try:
            subprocess.run([str(executable), str(fixture), str(git.resolve())], cwd=root, env=environment, check=True)
            passed = True
        finally:
            stopped = stop_fixture_groups(fixture)
            if stopped:
                print('Stopped owned fixture process groups: ' + str(stopped), flush=True)
                if passed:
                    raise RuntimeError('Receiver left fixture processes running after success')
