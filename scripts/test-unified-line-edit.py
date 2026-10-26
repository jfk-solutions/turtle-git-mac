#!/usr/bin/env python3
"""Grouped private native UDiff whole-line commands, byte provenance and ownership."""
import argparse
import os
from pathlib import Path
import shutil
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', action='append', choices=('commands','keyboard','bytes','drafts','ownership'))
parser.add_argument('--draft-command', choices=('deleteLine','cutLines'), help='Focused remaining native draft case')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
sources = root/'build/qa/unified-line-edit-native-sources'
sources.mkdir(parents=True, exist_ok=True)
receiver = build_receiver(root, [root/'docs/qa/unified-line-edit-native-2026-10-26.swift'], sources)
with tempfile.TemporaryDirectory(prefix='turtlegit-unified-line-edit-') as temporary:
    environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    environment.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),
                       GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0', GIT_OPTIONAL_LOCKS='0')
    for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
        folder = Path(temporary)/str(index); folder.mkdir()
        home = folder/'home'; home.mkdir(mode=0o700)
        private_temp = folder/'temporary'; private_temp.mkdir(mode=0o700)
        repository = folder/'repository'; repository.mkdir()
        environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home), TMPDIR=str(private_temp)+'/', XDG_CONFIG_HOME=str(folder/'xdg'))
        print('Checking private Unified Diff whole-line editor with '+str(git), flush=True)
        try:
            result = run_receiver([str(receiver), str(repository), str(git.absolute())] + (args.only or []) + (['draft-command='+args.draft_command] if args.draft_command else []), cwd=root, env=environment,
                                  capture_output=True, text=True, timeout_sample=folder/'timeout.sample.txt')
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if 'PASS Unified Diff line edit:' not in result.stdout:
                raise RuntimeError('Line-edit receiver exited before final behavioral/cleanup assertions')
        except BaseException:
            evidence = Path(tempfile.mkdtemp(prefix='unified-line-edit-failed-'+str(index)+'-', dir=root/'build/qa'))
            shutil.copytree(folder, evidence, dirs_exist_ok=True)
            print('Private failed fixture evidence: '+str(evidence), flush=True)
            raise
