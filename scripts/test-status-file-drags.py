#!/usr/bin/env python3
"""Actual outbound selected-file drags from Commit, Working Tree and Add lists."""
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
            raise RuntimeError('Cannot inspect private handoff helper ownership')
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
    raise RuntimeError('Verified private handoff producer survived cleanup')


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['commit', 'status', 'add'], action='append')
args = parser.parse_args()
root = next(parent for parent in Path(__file__).resolve().parents if (parent / 'Sources/TurtleGitMac').is_dir())
generated = root / 'build/qa/status-file-drags-native-sources'
generated.mkdir(parents=True, exist_ok=True)
receiver = build_receiver(root, [root / 'docs/qa/status-file-drags-native-2026-10-23.swift'], generated)
results = []
for engine_index, git in enumerate(args.git or [Path('/usr/bin/git'), root / 'build/git-runtime/Git/bin/git']):
    git = git.absolute()
    for case in args.only or ['commit', 'status', 'add']:
        with tempfile.TemporaryDirectory(prefix='turtlegit-status-drag-' + case + '-') as temporary:
            context = Path(temporary)
            for name in ['fixture', 'preferences', 'xdg', 'temporary', 'home']:
                (context / name).mkdir(mode=0o700)
            config = context / 'global.config'
            config.write_text('')
            environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
            environment.update(GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                               HOME=str(context / 'home'), CFFIXED_USER_HOME=str(context / 'preferences'),
                               XDG_CONFIG_HOME=str(context / 'xdg'), TMPDIR=str(context / 'temporary') + '/',
                               DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'))
            print('Checking status file drags ' + case + ' with ' + str(git), flush=True)
            passed = False
            try:
                result = run_receiver([str(receiver), str(context / 'fixture'), str(git), case],
                                      cwd=root, env=environment, capture_output=True, text=True,
                                      timeout_sample=context / 'timeout.sample.txt')
                print(result.stdout, end='')
                print(result.stderr, end='')
                passed = result.returncode == 0 and 'PASS: status file drags ' + case in result.stdout
                results.append(dict(git=str(git), case=case, returncode=result.returncode, passed=passed))
                (root / 'build/qa/status-file-drags-native-results.json').write_text(json.dumps(results, indent=2) + '\n')
                result.check_returncode()
                if not passed:
                    raise RuntimeError('Status drag receiver exited before completion')
            finally:
                sample = context / 'timeout.sample.txt'
                if sample.is_file():
                    shutil.copy2(sample, root / ('build/qa/status-file-drags-' + case + '-' + str(engine_index) + '-timeout.sample.txt'))
                approved = {str(git.resolve())}
                resolved = subprocess.run(['/usr/bin/xcrun', '--find', 'git'], capture_output=True, text=True)
                if resolved.returncode == 0:
                    approved.add(str(Path(resolved.stdout.strip()).resolve()))
                cleanup_needed = retire_owned_helpers(context, approved)
                if passed and cleanup_needed:
                    raise RuntimeError('Successful status drag case left owned helper processes running')
