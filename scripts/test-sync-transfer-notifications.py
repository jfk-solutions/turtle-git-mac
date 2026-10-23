#!/usr/bin/env python3
"""Actual Sync Fetch typed rows, workspace Log routing and owned producer retirement."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

from native_receiver import build_receiver, run_receiver


def retire_owned_helpers(context, approved_images):
    """Require both an exact executable and an open private fixture resource.

    Shell ownership additionally requires the exact authored wrapper argv. No
    unrelated application or process merely mentioning a fixture path is killed.
    """
    wrapper = context / 'fixture/held-helper'

    def owned():
        listing = subprocess.run(['/usr/sbin/lsof', '-t', '+D', str(context)],
                                 capture_output=True, text=True, timeout=10)
        if listing.returncode not in (0, 1):
            raise RuntimeError('Cannot inspect private Sync helper ownership')
        result = []
        for text in set(listing.stdout.split()):
            pid = int(text)
            executable = subprocess.run(['/usr/sbin/lsof', '-a', '-p', str(pid), '-d', 'txt', '-Fn'],
                                        capture_output=True, text=True, timeout=5)
            images = {str(Path(line[1:]).resolve()) for line in executable.stdout.splitlines() if line.startswith('n')}
            if images.intersection(approved_images):
                result.append(pid)
            elif str(Path('/bin/sh').resolve()) in images or '/bin/bash' in images:
                args = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'command='],
                                      capture_output=True, text=True, timeout=5).stdout.strip()
                if args.startswith('/bin/sh ' + str(wrapper) + ' ') or args == '/bin/sh ' + str(wrapper):
                    result.append(pid)
        return result

    needed = bool(owned())
    for number in (signal.SIGTERM, signal.SIGKILL):
        for pid in owned():
            if pid not in owned():
                continue
            try:
                group = os.getpgid(pid)
                os.killpg(group, number) if group == pid else os.kill(pid, number)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 3
        while owned() and time.monotonic() < deadline:
            time.sleep(.03)
        if not owned():
            return needed
    raise RuntimeError('Verified private Sync producer survived cleanup')


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['actual', 'separation', 'lifetime'], action='append')
parser.add_argument('--helper', type=Path)
parser.add_argument('--capture-dir', type=Path)
args = parser.parse_args()
root = next(parent for parent in Path(__file__).resolve().parents if (parent / 'Sources/TurtleGitMac').is_dir())
helper = (args.helper or root / 'build/libgit2-runtime/LibGit2/bin/turtlegit-libgit2').resolve()
if not helper.is_file() or not os.access(helper, os.X_OK):
    raise SystemExit('Build the actual pinned libgit2 runtime before the grouped checkpoint')
generated = root / 'build/qa/sync-transfer-notifications-native-sources'
generated.mkdir(parents=True, exist_ok=True)
receiver = build_receiver(root, [root / 'docs/qa/sync-transfer-notifications-native-2026-10-23.swift'], generated)
results = []
for engine_index, git in enumerate(args.git or [Path('/usr/bin/git'), root / 'build/git-runtime/Git/bin/git']):
    git = git.absolute()
    for case in args.only or ['actual', 'separation', 'lifetime']:
        with tempfile.TemporaryDirectory(prefix='turtlegit-sync-notifications-' + case + '-') as temporary:
            context = Path(temporary)
            for name in ['fixture', 'preferences', 'xdg', 'temporary', 'home']:
                (context / name).mkdir(mode=0o700)
            config = context / 'global.config'
            config.write_text('')
            environment = {key: value for key, value in os.environ.items()
                           if not key.startswith('GIT_') and key != 'TURTLEGIT_SYNC_TRANSFER_CAPTURES'}
            environment.update(GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                               HOME=str(context / 'home'), CFFIXED_USER_HOME=str(context / 'preferences'),
                               XDG_CONFIG_HOME=str(context / 'xdg'), TMPDIR=str(context / 'temporary') + '/',
                               DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'))
            if args.capture_dir and engine_index == 0 and case == 'actual':
                args.capture_dir.resolve().mkdir(parents=True, exist_ok=True)
                environment['TURTLEGIT_SYNC_TRANSFER_CAPTURES'] = str(args.capture_dir.resolve())
            print('Checking Sync transfer notifications ' + case + ' with ' + str(git), flush=True)
            passed = False
            try:
                result = run_receiver([str(receiver), str(context / 'fixture'), str(git), str(helper), case],
                                      cwd=root, env=environment, capture_output=True, text=True,
                                      timeout_sample=context / 'timeout.sample.txt')
                print(result.stdout, end='')
                print(result.stderr, end='')
                passed = result.returncode == 0 and 'PASS: Sync transfer notifications ' + case in result.stdout
                results.append(dict(git=str(git), case=case, returncode=result.returncode, passed=passed))
                (root / 'build/qa/sync-transfer-notifications-native-results.json').write_text(json.dumps(results, indent=2) + '\n')
                result.check_returncode()
                if not passed:
                    raise RuntimeError('Sync transfer notification receiver exited before completion')
            finally:
                sample = context / 'timeout.sample.txt'
                if sample.is_file():
                    shutil.copy2(sample, root / ('build/qa/sync-transfer-notifications-' + case + '-' + str(engine_index) + '-timeout.sample.txt'))
                (context / 'fixture/hold').unlink(missing_ok=True)
                cleanup_needed = retire_owned_helpers(context, {str(git.resolve()), str(helper)})
                if passed and cleanup_needed:
                    raise RuntimeError('Successful Sync case left owned helper processes running')
