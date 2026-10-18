#!/usr/bin/env python3
"""Grouped source Diff command/submodule comparison receiver; private fixtures."""
import argparse, os, tempfile
from pathlib import Path
from native_receiver import build_receiver, run_receiver
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-submodule-diff-entry-') as temporary:
    folder = Path(temporary)
    receiver = build_receiver(root, [root/'docs/qa/submodule-diff-entry-native-2026-10-18.swift'], folder)
    env = os.environ.copy()
    env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture = folder/str(index); fixture.mkdir()
        result = run_receiver([str(receiver), str(fixture), str(git.absolute())], cwd=root, env=env, capture_output=True, text=True)
        print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
        if 'PASS: Submodule Diff entry family:' not in result.stdout: raise SystemExit('Receiver exited before final assertion.')
