#!/usr/bin/env python3
"""Native Sync reference results and tag comparison; private data and owned windows."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['references', 'tags', 'ownership'], action='append')
parser.add_argument('--capture-dir', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-sync-reference-results-') as temporary:
    folder = Path(temporary)
    receiver = build_receiver(root, [root/'docs/qa/sync-reference-results-native-2026-10-20.swift'], folder)
    for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture = folder/str(index)
        fixture.mkdir()
        home = fixture/'home'
        home.mkdir()
        env = os.environ.copy()
        env.update(HOME=str(home), CFFIXED_USER_HOME=str(home), DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
        if args.capture_dir and index == 0:
            args.capture_dir.mkdir(parents=True, exist_ok=True)
            env['TURTLEGIT_SYNC_RESULT_CAPTURES'] = str(args.capture_dir.resolve())
        else:
            env.pop('TURTLEGIT_SYNC_RESULT_CAPTURES', None)
        print('Sync reference results: '+str(git), flush=True)
        result = run_receiver([str(receiver), str(fixture), str(git.absolute()), *(args.only or ['references', 'tags', 'ownership'])], cwd=root, env=env, timeout=180, capture_output=True, text=True)
        print(result.stdout, end='')
        print(result.stderr, end='')
        result.check_returncode()
        if 'PASS Sync reference results:' not in result.stdout:
            raise SystemExit('Receiver exited before final assertions')
