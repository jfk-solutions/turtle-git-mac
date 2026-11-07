#!/usr/bin/env python3
"""Cached, private native Export retained-result, ZIP and cancellation checks."""
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


def retire_owned_wrappers(context, git):
    """Only helpers retaining this request's exact lease files are owned."""
    leases = list(context.rglob('*.lease'))
    approved = {str(Path(name).resolve()) for name in ['/bin/sh', '/bin/sleep', str(git)]}

    def owned():
        result = set()
        for lease in leases:
            holders = subprocess.run(['/usr/sbin/lsof', '-t', '--', str(lease)],
                                     capture_output=True, text=True, timeout=10)
            if holders.returncode not in (0, 1):
                raise RuntimeError('Could not inspect private Export lease ownership')
            for value in holders.stdout.split():
                pid = int(value)
                images = subprocess.run(['/usr/sbin/lsof', '-a', '-p', str(pid), '-d', 'txt', '-Fn'],
                                        capture_output=True, text=True, timeout=5)
                actual = {str(Path(line[1:]).resolve()) for line in images.stdout.splitlines() if line.startswith('n')}
                if actual.intersection(approved):
                    result.add(pid)
        return result

    remaining = owned()
    needed = bool(remaining)
    for action in [signal.SIGTERM, signal.SIGKILL]:
        for pid in remaining:
            if pid not in owned():
                continue
            try:
                os.kill(pid, action)
            except ProcessLookupError:
                pass
        end = time.monotonic() + 3
        while time.monotonic() < end:
            remaining = owned()
            if not remaining:
                break
            time.sleep(.03)
        if not remaining:
            break
    if remaining:
        raise RuntimeError('Owned Export wrappers survived cleanup: ' + str(sorted(remaining)))
    return needed


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--receiver', type=Path, default=Path('docs/qa/export-progress-native-2026-10-08.swift'))
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
source = (root / args.receiver).resolve()
engines = [git.absolute() for git in args.git or [Path('/usr/bin/git')]]
for git in engines:
    if not git.is_file() or not os.access(git, os.X_OK):
        parser.error('Git executable missing or not executable: ' + str(git))
if not source.is_file():
    parser.error('Receiver source missing: ' + str(source))
cache = root / 'build/qa/export-progress-native-sources'
cache.mkdir(parents=True, exist_ok=True)
receiver = build_receiver(root, [source], cache)
for index, git in enumerate(engines):
    with tempfile.TemporaryDirectory(prefix='turtlegit-export-private-') as temporary:
        context = Path(temporary)
        fixture, preferences, xdg, scratch = [context / name for name in ['fixture', 'preferences', 'xdg', 'temporary']]
        for directory in [fixture, preferences, xdg, scratch]:
            directory.mkdir(mode=0o700)
        config = context / 'global.config'
        config.write_text('')
        environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
        environment.update(HOME=str(preferences), CFFIXED_USER_HOME=str(preferences),
                           XDG_CONFIG_HOME=str(xdg), TMPDIR=str(scratch) + '/',
                           GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                           DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'))
        complete = False
        log = ''
        print('Checking Export ' + source.name + ' with ' + str(git), flush=True)
        try:
            result = run_receiver([str(receiver), str(fixture), str(git)], cwd=root,
                                  env=environment, capture_output=True, text=True,
                                  timeout_sample=context / 'timeout.sample.txt')
            log = result.stdout + result.stderr
            print(result.stdout, end=''); print(result.stderr, end='')
            complete = result.returncode == 0 and ('Export:' in result.stdout or 'Export real ZIP/live output' in result.stdout)
            result.check_returncode()
            if not complete:
                raise RuntimeError('Export receiver exited before its final assertions')
        except subprocess.TimeoutExpired as error:
            log = '\n'.join(value.decode(errors='replace') if isinstance(value, bytes) else value or ''
                            for value in [error.stdout, error.stderr])
            raise
        finally:
            try:
                needed = retire_owned_wrappers(context, git)
                if complete and needed:
                    complete = False
                    raise RuntimeError('Export receiver reported success before retiring its owned wrapper')
            finally:
                if not complete:
                    failures = root / 'build/qa/native-export-progress-failures'
                    failures.mkdir(parents=True, exist_ok=True)
                    saved = Path(tempfile.mkdtemp(prefix=source.stem + '-' + str(index) + '-', dir=failures))
                    (saved / 'receiver.log').write_text(log[-262144:])
                    (saved / 'request.json').write_text(json.dumps({'receiver': str(source.relative_to(root)), 'git': str(git)}, indent=2) + '\n')
                    if (context / 'timeout.sample.txt').is_file():
                        shutil.copyfile(context / 'timeout.sample.txt', saved / 'timeout.sample.txt')
                    for file in fixture.rglob('*'):
                        if file.is_file() and file.suffix in ('.started', '.arguments', '.archive-output'):
                            target = saved / file.relative_to(fixture)
                            target.parent.mkdir(parents=True, exist_ok=True)
                            target.write_bytes(file.read_bytes()[:65536])
                    print('Retained Export failure evidence: ' + str(saved), flush=True)
