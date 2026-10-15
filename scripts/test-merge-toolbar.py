#!/usr/bin/env python3
"""Actual Compare/Merge AppKit toolbar workflows and owned cleanup."""
from pathlib import Path
import argparse
import os
import tempfile
from native_receiver import build_receiver, run_receiver
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='TurtleGitMergeToolbar-') as temporary:
    directory = Path(temporary)
    binary = build_receiver(root, [root / 'docs/qa/merge-toolbar-native-2026-10-15.swift'], directory)
    environment = os.environ.copy()
    environment.update(DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
    for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture = directory / str(index); fixture.mkdir()
        print('Checking native Merge toolbar with ' + str(git), flush=True)
        run_receiver([str(binary), str(fixture), str(git.absolute())], cwd=root, env=environment, check=True)
        assert (fixture / "completed").read_text() == "complete\n", "Receiver exited before its final behavioral assertion"
