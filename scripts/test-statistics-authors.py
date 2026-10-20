#!/usr/bin/env python3
"""Focused hidden native Statistics exact author identities and graph exports."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--artifacts', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-statistics-authors-') as temporary:
    directory = Path(temporary)
    receiver = build_receiver(root, [root / 'docs/qa/statistics-author-native-2026-10-20.swift'], directory)
    for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
        context = directory / str(index); context.mkdir(mode=0o700)
        fixture = context / 'fixture'; fixture.mkdir(mode=0o700)
        home = context / 'preferences'; home.mkdir(mode=0o700)
        xdg = context / 'xdg'; xdg.mkdir(mode=0o700)
        config = context / 'global.config'; config.write_text('')
        private_tmp = context / 'temporary'; private_tmp.mkdir(mode=0o700)
        env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
        env.update(GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                   CFFIXED_USER_HOME=str(home), XDG_CONFIG_HOME=str(xdg), TMPDIR=str(private_tmp),
                   DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'))
        if args.artifacts:
            env['TURTLEGIT_STATISTICS_AUTHOR_ARTIFACTS'] = str(args.artifacts.resolve() / ('engine-' + str(index)))
        print('Checking Statistics author identities with ' + str(git), flush=True)
        result = run_receiver([str(receiver), str(fixture), str(git.absolute())], cwd=root, env=env,
                              capture_output=True, text=True, timeout_sample=context / 'timeout.sample.txt')
        print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
        if 'PASS: Statistics exact author identities' not in result.stdout:
            raise SystemExit('Statistics author receiver exited before completion')
