#!/usr/bin/env python3
"""Hidden first-use Finder history/reference Services and owned native workflows."""
import argparse
import os
import signal
import shlex
import subprocess
import time
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

def release_owned_helpers(fixture, git):
    """Retire only journaled held-reader PIDs with a verified private identity."""
    journal = fixture / 'owned-read-pids'
    script = str(fixture / 'held-history-git')
    repository = str(fixture / 'authorityA')
    try:
        candidates = {int(value) for value in journal.read_text().splitlines() if value.isdigit()}
    except FileNotFoundError:
        candidates = set()
    if len(candidates) > 1000:
        raise RuntimeError('Invalid private helper PID journal')

    def identity(pid):
        result = subprocess.run(['ps', '-p', str(pid), '-o', 'pid=,pgid=,command='], text=True, capture_output=True)
        if result.returncode:
            return None
        fields = result.stdout.strip().split(None, 2)
        if len(fields) != 3 or int(fields[0]) != pid:
            return None
        try:
            arguments = shlex.split(fields[2])
        except ValueError:
            return None
        wrapped = script in arguments
        actual = bool(arguments) and arguments[0] == str(git.absolute()) and any(
            value == '-C' and index + 1 < len(arguments) and arguments[index + 1] == repository
            for index, value in enumerate(arguments))
        return (pid, int(fields[1])) if wrapped or actual else None

    def owned():
        return [found for pid in candidates if (found := identity(pid)) is not None]

    needed = bool(owned())
    (fixture / 'release-read').write_bytes(b'')
    deadline = time.monotonic() + 2
    while owned() and time.monotonic() < deadline:
        time.sleep(.02)
    for sig in [signal.SIGTERM, signal.SIGKILL]:
        for pid, group in owned():
            # A journaled PID can have exited/recycled after enumeration. Check
            # the exact wrapper/private-repository identity immediately again.
            if identity(pid) != (pid, group):
                continue
            try:
                if group == pid:
                    os.killpg(group, sig)
                else:
                    os.kill(pid, sig)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 2
        while owned() and time.monotonic() < deadline:
            time.sleep(.02)
    if owned():
        raise RuntimeError('Verified private history helper did not terminate')
    if needed:
        print('Cleanup required for journaled private history helper after receiver exit', flush=True)
    return needed

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['provider', 'routes', 'ownership'], action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-finder-history-services-') as temporary:
    directory = Path(temporary)
    receiver = build_receiver(root, [root / 'docs/qa/finder-history-services-native-2026-10-21.swift'], directory)
    for case in args.only or ['provider', 'routes', 'ownership']:
        engines = [Path('/usr/bin/git')] if case == 'provider' else args.git or [Path('/usr/bin/git')]
        for index, git in enumerate(engines):
            context = directory / (case + str(index)); context.mkdir(mode=0o700)
            fixture = context / 'fixture'; fixture.mkdir(mode=0o700)
            preferences = context / 'preferences'; preferences.mkdir(mode=0o700)
            xdg = context / 'xdg'; xdg.mkdir(mode=0o700)
            config = context / 'global.config'; config.write_text('[protocol "file"]\n    allow = always\n')
            private_tmp = context / 'temporary'; private_tmp.mkdir(mode=0o700)
            env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
            env.update(GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                       CFFIXED_USER_HOME=str(preferences), XDG_CONFIG_HOME=str(xdg), TMPDIR=str(private_tmp),
                       DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'), TURTLEGIT_FINDER_HISTORY_SERVICES_CASE=case)
            print('Checking history Finder Services ' + case + ' with ' + str(git), flush=True)
            completed = False
            sample = root / 'build/qa' / ('finder-history-services-' + case + '-' + str(index) + '-' + str(time.time_ns()) + '.sample.txt')
            try:
                result = run_receiver([str(receiver), str(fixture), str(git.absolute()), str(root / 'Configuration/App-Info.plist')],
                                      cwd=root, env=env, capture_output=True, text=True, timeout_sample=sample)
                print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
                if 'PASS: history Services case completed' not in result.stdout:
                    raise SystemExit('History Services receiver exited before completion')
                completed = True
            finally:
                needed = release_owned_helpers(fixture, git)
                if needed and completed:
                    raise RuntimeError('Successful history receiver left a verified test-owned helper alive')
