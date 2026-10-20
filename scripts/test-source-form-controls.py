#!/usr/bin/env python3
"""Grouped native reference-form and Push/Sync source controls; private data."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['references', 'transport'], action='append')
parser.add_argument('--capture-dir', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-source-form-controls-') as temporary:
    folder = Path(temporary)
    receiver = build_receiver(root, [root/'docs/qa/source-form-controls-native-2026-10-20.swift'], folder)
    for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture = folder/str(index)
        fixture.mkdir()
        home = fixture/'home'
        home.mkdir()
        env = os.environ.copy()
        env.update(HOME=str(home), CFFIXED_USER_HOME=str(home), DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
        if args.capture_dir and index == 0:
            args.capture_dir.mkdir(parents=True, exist_ok=True)
            env['TURTLEGIT_SOURCE_FORM_CAPTURES'] = str(args.capture_dir.resolve())
        else:
            env.pop('TURTLEGIT_SOURCE_FORM_CAPTURES', None)
        print('Source form controls: '+str(git), flush=True)
        result = run_receiver([str(receiver), str(fixture), str(git.absolute()), *(args.only or ['references', 'transport'])], cwd=root, env=env, timeout=180, capture_output=True, text=True)
        print(result.stdout, end='')
        print(result.stderr, end='')
        result.check_returncode()
        if 'PASS source form controls:' not in result.stdout:
            raise SystemExit('Receiver exited before final assertions')
