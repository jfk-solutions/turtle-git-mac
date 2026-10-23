#!/usr/bin/env python3
"""Grouped actual Graph viewport zoom, source keys and pointer owner retirement."""
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
    """Only signal approved executable images holding this private fixture tree."""
    def owned():
        listing = subprocess.run(['/usr/sbin/lsof', '-t', '+D', str(context)],
                                 capture_output=True, text=True, timeout=10)
        if listing.returncode not in (0, 1):
            raise RuntimeError('Cannot inspect private Graph viewport helper ownership')
        result = []
        for value in set(listing.stdout.split()):
            pid = int(value)
            executable = subprocess.run(['/usr/sbin/lsof', '-a', '-p', str(pid), '-d', 'txt', '-Fn'],
                                        capture_output=True, text=True, timeout=5)
            images = {str(Path(line[1:]).resolve()) for line in executable.stdout.splitlines()
                      if line.startswith('n')}
            if images.intersection(approved_images):
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
    raise RuntimeError('Verified private Graph viewport helper survived cleanup')


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['zoom', 'gestures', 'retirement'], action='append')
parser.add_argument('--layout', type=Path)
args = parser.parse_args()
root = next(parent for parent in Path(__file__).resolve().parents
            if (parent / 'Sources/TurtleGitMac').is_dir())
generated = root / 'build/qa/graph-viewport-family-native-sources'
generated.mkdir(parents=True, exist_ok=True)
layout = (args.layout or root / 'build/graph-layout-runtime/GraphLayout/graph-layout').resolve()
if not layout.is_file() or not os.access(layout, os.X_OK):
    raise SystemExit('Build the actual pinned graph layout runtime before this grouped checkpoint')
receiver = build_receiver(root, [root / 'docs/qa/graph-viewport-native-2026-10-23.swift'], generated)
results = []
for engine_index, git in enumerate(args.git or [Path('/usr/bin/git'), root / 'build/git-runtime/Git/bin/git']):
    git = git.absolute()
    for case in args.only or ['zoom', 'gestures', 'retirement']:
        with tempfile.TemporaryDirectory(prefix='turtlegit-graph-viewport-' + case + '-') as temporary:
            context = Path(temporary)
            fixture = context / 'fixture'
            preferences = context / 'preferences'
            xdg = context / 'xdg'
            scratch = context / 'temporary'
            for directory in [fixture, preferences, xdg, scratch]:
                directory.mkdir(mode=0o700)
            config = context / 'global.config'
            config.write_text('')
            environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
            environment.update(GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                               CFFIXED_USER_HOME=str(preferences), XDG_CONFIG_HOME=str(xdg), TMPDIR=str(scratch) + '/',
                               DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'))
            print('Checking Graph viewport ' + case + ' with ' + str(git), flush=True)
            passed = False
            try:
                result = run_receiver([str(receiver), str(fixture), str(git), str(layout), case],
                                      cwd=root, env=environment, capture_output=True, text=True,
                                      timeout_sample=context / 'timeout.sample.txt')
                print(result.stdout, end='')
                print(result.stderr, end='')
                passed = result.returncode == 0 and 'PASS: Graph viewport family ' + case in result.stdout
                results.append(dict(git=str(git), case=case, returncode=result.returncode, passed=passed))
                (root / 'build/qa/graph-viewport-family-native-results.json').write_text(json.dumps(results, indent=2) + '\n')
                result.check_returncode()
                if not passed:
                    raise RuntimeError('Graph viewport receiver exited before completion')
            finally:
                sample = context / 'timeout.sample.txt'
                if sample.is_file():
                    shutil.copy2(sample, root / ('build/qa/graph-viewport-' + case + '-' + str(engine_index) + '-timeout.sample.txt'))
                cleanup_needed = retire_owned_helpers(context, {str(git.resolve()), str(layout)})
                if passed and cleanup_needed:
                    raise RuntimeError('Successful Graph viewport case left owned Git/layout helpers running')
