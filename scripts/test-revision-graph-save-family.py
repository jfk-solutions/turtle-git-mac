#!/usr/bin/env python3
"""Grouped native graph destination, save ownership and hidden output checks."""
import argparse
import json
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', action='append', type=Path)
parser.add_argument('--only', action='append', choices=['formats', 'ownership', 'command'])
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
directory = root / 'build/qa/revision-graph-save-native-sources'
directory.mkdir(parents=True, exist_ok=True)
receiver = build_receiver(root, [root / 'docs/qa/revision-graph-save-native-2026-10-21.swift'], directory)
results = []
for git in args.git or [Path('/usr/bin/git'), root / 'build/git-runtime/Git/bin/git']:
    for case in args.only or ['formats', 'ownership', 'command']:
        with tempfile.TemporaryDirectory(prefix='turtlegit-graph-save-' + case + '-') as temporary:
            base = Path(temporary)
            scratch = base / 'temporary'
            scratch.mkdir(mode=0o700)
            config = base / 'global.config'
            config.write_text('')
            environment = dict(os.environ, TMPDIR=str(scratch)+'/', DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0', XDG_CONFIG_HOME=str(base/'xdg'))
            for key in ['GIT_CONFIG_PARAMETERS', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR', 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_AUTHOR_DATE', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL', 'GIT_COMMITTER_DATE']:
                environment.pop(key, None)
            result = run_receiver([str(receiver), str(base), str(git.absolute()), case], cwd=root, env=environment, capture_output=True, text=True, timeout_sample=base/'timeout.sample.txt')
            print(result.stdout, end='')
            print(result.stderr, end='')
            results.append(dict(git=str(git.absolute()), case=case, returncode=result.returncode, passed=result.returncode == 0 and 'PASS: Revision Graph save '+case in result.stdout))
            (root/'build/qa/revision-graph-save-native-results.json').write_text(json.dumps(results, indent=2)+'\n')
            result.check_returncode()
            if not results[-1]['passed']:
                raise SystemExit('Graph save receiver exited before completion')
