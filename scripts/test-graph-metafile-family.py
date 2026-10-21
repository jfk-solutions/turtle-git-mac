#!/usr/bin/env python3
"""Native vector graph scenes, enhanced-metafile export and save ownership."""
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


def retire_owned_helpers(context, approved):
    """Only approved helper executables holding this private request are owned."""
    def owned():
        holders = subprocess.run(['/usr/sbin/lsof', '-t', '+D', str(context)],
                                 capture_output=True, text=True, timeout=10)
        if holders.returncode not in (0, 1):
            raise RuntimeError('Could not inspect private graph request ownership')
        result = []
        for value in set(holders.stdout.split()):
            pid = int(value)
            images = subprocess.run(['/usr/sbin/lsof', '-a', '-p', str(pid), '-d', 'txt', '-Fn'],
                                    capture_output=True, text=True, timeout=5)
            actual = {str(Path(line[1:]).resolve()) for line in images.stdout.splitlines() if line.startswith('n')}
            if actual.intersection(approved):
                result.append(pid)
        return result

    remaining = owned()
    cleanup_needed = bool(remaining)
    for action in [signal.SIGTERM, signal.SIGKILL]:
        for pid in remaining:
            if pid not in owned():
                continue
            try:
                group = os.getpgid(pid)
                os.killpg(group, action) if group == pid else os.kill(pid, action)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            remaining = owned()
            if not remaining:
                break
            time.sleep(.03)
        if not remaining:
            break
    if remaining:
        raise RuntimeError('Owned approved graph helper survived cleanup: ' + str(remaining))
    return cleanup_needed


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['statistics', 'revision', 'ownership'], action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
cache = root / 'build/qa/graph-metafile-family-native-sources'
cache.mkdir(parents=True, exist_ok=True)
receiver = build_receiver(root, [root / 'docs/qa/graph-metafile-family-native-2026-10-21.swift'], cache)
approved = {str(path.resolve()) for path in [
    root / 'build/metafile-runtime/Metafile/metafile-convert',
    root / 'build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/Metafile/metafile-convert',
    root / 'build/graph-layout-runtime/GraphLayout/graph-layout',
    root / 'build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/GraphLayout/graph-layout',
] if path.is_file()}
results = []
for case in args.only or ['statistics', 'revision', 'ownership']:
    for index, git in enumerate(args.git or [Path('/usr/bin/git'), root / 'build/git-runtime/Git/bin/git']):
        with tempfile.TemporaryDirectory(prefix='turtlegit-graph-metafile-' + case + '-') as temporary:
            context = Path(temporary)
            fixture, preferences, xdg, scratch = [context / name for name in ['fixture', 'preferences', 'xdg', 'temporary']]
            for directory in [fixture, preferences, xdg, scratch]:
                directory.mkdir(mode=0o700)
            config = context / 'global.config'
            config.write_text('')
            environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
            environment.update(DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'),
                               GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                               CFFIXED_USER_HOME=str(preferences), XDG_CONFIG_HOME=str(xdg), TMPDIR=str(scratch) + '/')
            print('Checking graph metafile ' + case + ' with ' + str(git), flush=True)
            completed = False
            try:
                result = run_receiver([str(receiver), str(fixture), str(git.absolute()),
                                       case],
                                      cwd=root, env=environment, capture_output=True, text=True,
                                      timeout_sample=context / 'timeout.sample.txt')
                print(result.stdout, end='')
                print(result.stderr, end='')
                completed = result.returncode == 0 and 'PASS: graph metafile family ' + case in result.stdout
                results.append(dict(git=str(git.absolute()), case=case, returncode=result.returncode, passed=completed))
                (root / 'build/qa/graph-metafile-family-native-results.json').write_text(json.dumps(results, indent=2) + '\n')
                result.check_returncode()
                if not completed:
                    raise SystemExit('Graph metafile receiver exited before completion')
            finally:
                artifacts = fixture / 'artifacts'
                if not completed and artifacts.is_dir():
                    destination = root / ('build/qa/graph-metafile-family-failure-' + case + '-' + str(index))
                    shutil.copytree(artifacts, destination, dirs_exist_ok=True)
                sample = context / 'timeout.sample.txt'
                if sample.is_file():
                    shutil.copyfile(sample, root / ('build/qa/graph-metafile-family-' + case + '-' + str(index) + '.sample.txt'))
                cleaned = retire_owned_helpers(context, approved)
                if completed and cleaned:
                    results[-1]['passed'] = False
                    results[-1]['helper_cleanup_needed'] = True
                    (root / 'build/qa/graph-metafile-family-native-results.json').write_text(json.dumps(results, indent=2) + '\n')
                    raise RuntimeError('Approved graph helper outlived a completed native request')
