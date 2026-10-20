#!/usr/bin/env python3
"""Actual bundled masked-metafile helper through hidden comparison/conflict consumers."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
from native_receiver import build_receiver, run_receiver


def retire_owned_metafile_helpers(context, approved):
    """Private request open files AND exact approved executable identify ownership."""
    def owned():
        holders = subprocess.run(['/usr/sbin/lsof', '-t', '+D', str(context)], capture_output=True, text=True, timeout=10)
        if holders.returncode not in (0, 1):
            raise RuntimeError('Could not inspect private metafile request ownership')
        result = []
        for value in set(holders.stdout.split()):
            pid = int(value)
            text = subprocess.run(['/usr/sbin/lsof', '-a', '-p', str(pid), '-d', 'txt', '-Fn'], capture_output=True, text=True, timeout=5)
            images = {str(Path(line[1:]).resolve()) for line in text.stdout.splitlines() if line.startswith('n')}
            if images.intersection(approved):
                result.append(pid)
        return result
    leftovers = owned()
    needed_cleanup = bool(leftovers)
    for number in [signal.SIGTERM, signal.SIGKILL]:
        for pid in leftovers:
            # Revalidate the open request and executable before signaling a PID.
            if pid not in owned():
                continue
            try:
                group = os.getpgid(pid)
                os.killpg(group, number) if group == pid else os.kill(pid, number)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            leftovers = owned()
            if not leftovers:
                break
            time.sleep(.03)
        if not leftovers:
            break
    if leftovers:
        raise RuntimeError('Owned approved metafile helper survived cleanup: ' + str(leftovers))
    return needed_cleanup


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['consumers', 'conflict'], action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
approved = {str(path.resolve()) for path in [
    root / 'build/metafile-runtime/Metafile/metafile-convert',
    root / 'build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/Metafile/metafile-convert',
] if path.is_file()}
with tempfile.TemporaryDirectory(prefix='turtlegit-masked-metafile-native-') as temporary:
    directory = Path(temporary)
    receiver = build_receiver(root, [root / 'docs/qa/metafile-masked-transfers-native-2026-10-20.swift'], directory)
    for case in args.only or ['consumers', 'conflict']:
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            context = directory / (case + str(index)); context.mkdir(mode=0o700)
            fixture = context / 'fixture'; fixture.mkdir(mode=0o700)
            private_tmp = context / 'temporary'; private_tmp.mkdir(mode=0o700)
            preferences = context / 'preferences'; preferences.mkdir(mode=0o700)
            xdg = context / 'xdg'; xdg.mkdir(mode=0o700)
            config = context / 'global.config'; config.write_text('')
            env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
            env.update(DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=str(config),
                       GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0', CFFIXED_USER_HOME=str(preferences),
                       XDG_CONFIG_HOME=str(xdg), TMPDIR=str(private_tmp) + '/', TURTLEGIT_MASKED_METAFILE_CASE=case)
            print('Checking masked metafile ' + case + ' with ' + str(git), flush=True)
            completed = False
            try:
                result = run_receiver([str(receiver), str(fixture), str(git.absolute()), str(root / 'Tests/TurtleGitCoreTests/Fixtures/Metafile')],
                                      cwd=root, env=env, capture_output=True, text=True, timeout_sample=context / 'timeout.sample.txt')
                print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
                if 'PASS: masked metafile native case completed' not in result.stdout:
                    raise SystemExit('Masked metafile receiver exited before completion')
                completed = True
            finally:
                cleaned = retire_owned_metafile_helpers(context, approved)
                if completed and cleaned:
                    raise RuntimeError('Approved metafile helper outlived a completed native request')
