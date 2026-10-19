#!/usr/bin/env python3
"""Grouped native opt-in Reset/Log commit-revert selected-backend result checks."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['reset', 'revert', 'lifecycle'], action='append')
parser.add_argument('--helper', type=Path, help='Use this packaged/prepared libgit2 helper.')
parser.add_argument('--captures', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
sources = root/'build/qa/reset-backend-notification-sources'
sources.mkdir(parents=True, exist_ok=True)
fixture = root/'docs/qa/reset-backend-notifications-native-2026-10-19.swift'
receiver = build_receiver(root, [fixture], sources)
with tempfile.TemporaryDirectory(prefix='turtlegit-reset-backend-') as temporary:
    base = {key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
    base.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for case in args.only or ['reset', 'revert', 'lifecycle']:
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            directory = Path(temporary)/(case+str(index)); directory.mkdir()
            config = directory/'global.config'; config.write_text('')
            private_tmp = directory/'temporary'; private_tmp.mkdir(mode=0o700)
            env = dict(base, GIT_CONFIG_GLOBAL=str(config), XDG_CONFIG_HOME=str(directory/'xdg'), TMPDIR=str(private_tmp), TURTLEGIT_RESET_BACKEND_CASE=case)
            if args.helper:
                env['TURTLEGIT_RESET_BACKEND_HELPER'] = str(args.helper.absolute())
            if args.captures and index == 0 and case in ['reset']:
                env['TURTLEGIT_RESET_BACKEND_CAPTURES'] = str(args.captures.absolute())
            else:
                env.pop('TURTLEGIT_RESET_BACKEND_CAPTURES', None)
            print('Checking reset backend '+case+' with '+str(git), flush=True)
            result = run_receiver([str(receiver), str(directory), str(git.absolute())], cwd=root, env=env,
                                  capture_output=True, text=True, timeout_sample=directory/'timeout.sample.txt')
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if 'PASS: reset backend native case completed' not in result.stdout:
                raise SystemExit('Reset backend receiver exited before completion: '+case)
