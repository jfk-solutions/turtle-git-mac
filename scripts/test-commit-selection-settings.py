#!/usr/bin/env python3
"""Headless native Commit selection-settings workflow checks; no displayed prompt or signed UI acceptance."""
from native_receiver import build_receiver, run_receiver
import argparse
import os
from pathlib import Path
import platform
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='turtlegit-selection-settings-native-') as temporary:
    directory = Path(temporary)
    executable = build_receiver(root, [root / 'docs/qa/commit-selection-settings-native-2026-10-07.swift'], directory)
    for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture = directory / ('fixture-' + str(index)); fixture.mkdir()
        home = directory / ('home-' + str(index)); home.mkdir(mode=0o700)
        private_tmp = directory / ('tmp-' + str(index)); private_tmp.mkdir(mode=0o700)
        config = directory / ('config-' + str(index)); config.write_text('')
        environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
        environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home), XDG_CONFIG_HOME=str(home / 'xdg'),
                           TMPDIR=str(private_tmp) + '/', GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1',
                           GIT_CONFIG_COUNT='0', DYLD_FRAMEWORK_PATH=str(products))
        print('Checking ' + str(git), flush=True)
        run_receiver([str(executable), str(fixture), str(git.resolve())], cwd=root, env=environment, check=True)
