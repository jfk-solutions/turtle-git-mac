#!/usr/bin/env python3
"""Hidden native Submodule Sync progress and local Git fixtures; no network."""
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
products = root/'build/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='turtlegit-submodule-sync-native-') as temporary:
    directory = Path(temporary)
    executable = build_receiver(root, [root / 'docs/qa/submodule-sync-native-2026-10-09.swift'], directory)
    environment = os.environ.copy(); environment['DYLD_FRAMEWORK_PATH'] = str(products)
    for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture = directory/str(index); fixture.mkdir(mode=0o700)
        run_receiver([str(executable),str(fixture),str(git.resolve())],cwd=root,env=environment,check=True)
