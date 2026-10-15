#!/usr/bin/env python3
"""Owned native conflict identities; optional light/dark native-view captures."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--captures', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
if args.captures:
    args.captures = args.captures.absolute()
    args.captures.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='TurtleGitConflictIdentities-') as temporary:
    directory = Path(temporary)
    support = directory / 'TwoPaneSupport.swift'
    support.write_text((root / 'docs/qa/two-pane-engine-native-2026-10-12.swift').read_text().replace('@main struct', 'struct', 1))
    executable = build_receiver(root, [root / 'docs/qa/conflict-identities-native-2026-10-15.swift', support, root / 'docs/qa/merge-wrapping-native-2026-10-12.swift'], directory)
    environment = os.environ.copy()
    environment.update(DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
    for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture = directory / str(index); fixture.mkdir()
        print('Checking conflict identities with ' + str(git), flush=True)
        run_receiver([str(executable), str(fixture), str(git.absolute()), *([str(args.captures)] if args.captures and index == 0 else [])], cwd=root, env=environment, check=True)
