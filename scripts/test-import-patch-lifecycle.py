#!/usr/bin/env python3
"""Grouped native Import Patch identity, reviewed recovery and owned worker lifetime."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['identity', 'recovery', 'lifetime'], action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-import-patch-lifecycle-') as temporary:
    directory = Path(temporary)
    receiver = build_receiver(root, [root / 'docs/qa/import-patch-lifecycle-2026-10-20.swift'], directory)
    for case in args.only or ['identity', 'recovery', 'lifetime']:
        engines = args.git or [Path('/usr/bin/git')]
        for index, git in enumerate(engines):
            context = directory / (case + str(index)); context.mkdir(mode=0o700)
            fixture = context / 'fixture'; fixture.mkdir(mode=0o700)
            home = context / 'private-preferences'; home.mkdir(mode=0o700)
            xdg = context / 'xdg'; xdg.mkdir(mode=0o700)
            config = context / 'global.config'; config.write_text('')
            private_tmp = context / 'temporary'; private_tmp.mkdir(mode=0o700)
            env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
            env.update(GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                       CFFIXED_USER_HOME=str(home), XDG_CONFIG_HOME=str(xdg), TMPDIR=str(private_tmp),
                       DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'),
                       TURTLEGIT_IMPORT_SAFETY_CASE=case)
            print('Checking Import Patch lifecycle ' + case + ' with ' + str(git), flush=True)
            result = run_receiver([str(receiver), str(fixture), str(git.absolute())],
                                  cwd=root, env=env, capture_output=True, text=True,
                                  timeout_sample=context / 'timeout.sample.txt')
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if 'PASS: Import Patch lifecycle case completed' not in result.stdout:
                raise SystemExit('Receiver exited before completing Import Patch lifecycle: ' + case)
