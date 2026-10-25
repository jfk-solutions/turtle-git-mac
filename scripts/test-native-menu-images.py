#!/usr/bin/env python3
"""Check lazy native images, menu lifecycle and actual Log private preferences."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-menu-images-') as temporary:
    context = Path(temporary).resolve()
    for name in ['fixture', 'preferences', 'temporary', 'home', 'xdg']:
        (context / name).mkdir(mode=0o700)
    config = context / 'global.config'; config.write_text('')
    receiver = build_receiver(root, [root / 'docs/qa/menu-image-visibility-native-2026-10-25.swift'], context)
    environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    environment.update(GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                       CFFIXED_USER_HOME=str(context / 'preferences'), HOME=str(context / 'home'),
                       XDG_CONFIG_HOME=str(context / 'xdg'), TMPDIR=str(context / 'temporary') + '/',
                       DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'))
    git = (args.git or root / 'build/git-runtime/Git/bin/git').absolute()
    result = run_receiver([str(receiver), str(context / 'fixture'), str(git)], cwd=root,
                          env=environment, capture_output=True, text=True,
                          timeout_sample=context / 'timeout.sample.txt')
    print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
    if 'PASS: native menu visibility' not in result.stdout:
        raise SystemExit('Menu image receiver did not finish its assertions')
