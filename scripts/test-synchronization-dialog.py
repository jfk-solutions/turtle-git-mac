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
parser.add_argument('--git', type=Path, action='append')
selection = parser.add_mutually_exclusive_group()
selection.add_argument('--push-only', action='store_true', help='Run the native Push fixture only.')
selection.add_argument('--apply-only', action='store_true', help='Run the native Apply Patch fixture only.')
selection.add_argument('--branches-only', action='store_true', help='Run the native local/remote branch picker fixture only.')
selection.add_argument('--manage-only', action='store_true', help='Run the native Manage Remote settings fixture only.')
selection.add_argument('--stash-only', action='store_true', help='Run the native Stash fixture only.')
selection.add_argument('--submodules-only', action='store_true', help='Run the native Submodule fixture only.')
selection.add_argument('--tags-only', action='store_true', help='Run the native Compare Tags fixture only.')
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
    # Git's system executable may strip DYLD_* before launching the sequence
    # editor. The temporary receiver needs its own framework search path.
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-target', platform.machine() + '-apple-macos13.0', '-I', str(products), '-F', str(products), *sources, str(copy), str(root / 'docs/qa/synchronization-native-2026-10-11.swift'), str(root / 'docs/qa/synchronization-apply-native-2026-10-11.swift'), '-framework', 'TurtleGitCore', '-Xlinker', '-rpath', '-Xlinker', str(products), '-o', str(executable)], cwd=root, check=True)
    environment = os.environ.copy()
    environment['DYLD_FRAMEWORK_PATH'] = str(products)
    if args.tags_only: environment['TURTLEGIT_SYNC_TAGS_ONLY'] = '1'
    if args.push_only: environment['TURTLEGIT_SYNC_PUSH_ONLY'] = '1'
    if args.submodules_only: environment['TURTLEGIT_SYNC_SUBMODULES_ONLY'] = '1'
    if args.apply_only: environment['TURTLEGIT_SYNC_APPLY_ONLY'] = '1'
    if args.branches_only: environment['TURTLEGIT_SYNC_BRANCHES_ONLY'] = '1'
    if args.manage_only: environment['TURTLEGIT_SYNC_MANAGE_ONLY'] = '1'
    if args.stash_only: environment['TURTLEGIT_SYNC_STASH_ONLY'] = '1'
    for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture = directory / ('fixture-' + str(index)); fixture.mkdir()
        print('Checking ' + str(git), flush=True)
        receiver = subprocess.Popen([str(executable), str(fixture), str(git.resolve())], cwd=root, env=environment, start_new_session=True)
        try:
            code = receiver.wait(timeout=600)
            if code:
                raise subprocess.CalledProcessError(code, receiver.args)
        finally:
            close_receiver(receiver)
