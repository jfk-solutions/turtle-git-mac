#!/usr/bin/env python3
"""Grouped native file-list drag receipts, delivery and owned cancellation."""
import argparse
import json
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', action='append', type=Path)
parser.add_argument('--helper', type=Path)
parser.add_argument('--only', choices=['lists', 'delivery', 'ownership'], action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
helper = (args.helper or root/'build/libgit2-runtime/LibGit2/bin/turtlegit-libgit2').absolute()
folder = root/'build/qa/file-list-drag-native-sources'
folder.mkdir(parents=True, exist_ok=True)
receiver = build_receiver(root, [root/'docs/qa/file-list-drag-native-2026-10-21.swift'], folder)
results = []
for git in args.git or [Path('/usr/bin/git'), root/'build/git-runtime/Git/bin/git']:
    for case in args.only or ['lists', 'delivery', 'ownership']:
        with tempfile.TemporaryDirectory(prefix='turtlegit-file-drag-'+case+'-') as temporary:
            private = Path(temporary)
            scratch = private/'temporary'; scratch.mkdir(mode=0o700)
            config = private/'global.config'; config.write_text('')
            environment = dict(os.environ, TMPDIR=str(scratch)+'/',
                DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),
                GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                XDG_CONFIG_HOME=str(private/'xdg'))
            for key in ['GIT_CONFIG_PARAMETERS', 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_AUTHOR_DATE',
                        'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL', 'GIT_COMMITTER_DATE']:
                environment.pop(key, None)
            result = run_receiver([str(receiver), str(private), str(git.absolute()), str(helper), case],
                cwd=root, env=environment, capture_output=True, text=True,
                timeout_sample=private/'timeout.sample.txt')
            print(result.stdout, end=''); print(result.stderr, end='')
            results.append(dict(git=str(git.absolute()), case=case, returncode=result.returncode,
                                passed=result.returncode == 0 and 'PASS: file-list drag '+case in result.stdout))
            (root/'build/qa/file-list-drag-native-results.json').write_text(json.dumps(results, indent=2)+'\n')
            result.check_returncode()
            if not results[-1]['passed']:
                raise SystemExit('File-list drag receiver exited before completion')
