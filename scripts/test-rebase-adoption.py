#!/usr/bin/env python3
"""Focused hidden native paused Rebase session adoption workflows."""
import argparse
import os
import signal
import subprocess
import time
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

def release_owned_helpers(fixture):
    """A Swift trap skips defer; release and retire only this private fixture's helpers."""
    (fixture / 'release-read').write_bytes(b'')
    def owned():
        rows = subprocess.check_output(['ps', '-axo', 'pid=,pgid=,args='], text=True).splitlines()
        result = []
        for row in rows:
            fields = row.strip().split(None, 2)
            if len(fields) == 3 and str(fixture) + '/' in fields[2]:
                result.append((int(fields[0]), int(fields[1])))
        return result
    deadline = time.monotonic() + 2
    while owned() and time.monotonic() < deadline:
        time.sleep(.02)
    remaining = owned()
    for pid, group in remaining:
        try:
            if group == pid: os.killpg(group, signal.SIGTERM)
            else: os.kill(pid, signal.SIGTERM)
        except ProcessLookupError: pass
    deadline = time.monotonic() + 2
    while owned() and time.monotonic() < deadline:
        time.sleep(.02)
    for pid, group in owned():
        try:
            if group == pid: os.killpg(group, signal.SIGKILL)
            else: os.kill(pid, signal.SIGKILL)
        except ProcessLookupError: pass
    deadline = time.monotonic() + 2
    while owned() and time.monotonic() < deadline:
        time.sleep(.02)
    if owned(): raise RuntimeError('Owned private Rebase adoption helper did not terminate')

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['linear', 'structural', 'ownership'], action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-rebase-adoption-') as temporary:
    directory = Path(temporary)
    receiver = build_receiver(root, [root / 'docs/qa/rebase-adoption-native-2026-10-20.swift'], directory)
    for case in args.only or ['linear', 'structural', 'ownership']:
        engines = args.git or [Path('/usr/bin/git')]
        for index, git in enumerate(engines):
            context = directory / (case + str(index)); context.mkdir(mode=0o700)
            fixture = context / 'fixture'; fixture.mkdir(mode=0o700)
            preferences = context / 'preferences'; preferences.mkdir(mode=0o700)
            xdg = context / 'xdg'; xdg.mkdir(mode=0o700)
            config = context / 'global.config'; config.write_text('')
            private_tmp = context / 'temporary'; private_tmp.mkdir(mode=0o700)
            env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
            env.update(GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                       CFFIXED_USER_HOME=str(preferences), XDG_CONFIG_HOME=str(xdg), TMPDIR=str(private_tmp),
                       DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'), TURTLEGIT_REBASE_ADOPTION_CASE=case)
            print('Checking Rebase adoption ' + case + ' with ' + str(git), flush=True)
            try:
                result = run_receiver([str(receiver), str(fixture), str(git.absolute()), str(root / 'build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac')],
                                      cwd=root, env=env, capture_output=True, text=True, timeout_sample=context / 'timeout.sample.txt')
                print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
                if 'PASS: Rebase adoption case completed' not in result.stdout:
                    raise SystemExit('Rebase adoption receiver exited before completion')
            finally:
                release_owned_helpers(fixture)
