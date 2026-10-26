#!/usr/bin/env python3
"""Grouped private native Unified Diff logical-line gutter workflow."""
import argparse
import hashlib
import os
import shutil
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--capture-only', action='store_true', help='Capture actual hosted components and geometry without repeating behavioral/Git checks')
parser.add_argument('--geometry-only', action='store_true', help='Affected viewport extent, wrapping, scrolling and native capture check')
args = parser.parse_args()
if args.geometry_only and args.capture_only:
    parser.error('--geometry-only and --capture-only are mutually exclusive')
root = Path(__file__).resolve().parent.parent
sources = root/'build/qa/unified-gutter-native-sources'
sources.mkdir(parents=True, exist_ok=True)
receiver = build_receiver(root, [root/'docs/qa/unified-gutter-native-2026-10-26.swift'], sources)
with tempfile.TemporaryDirectory(prefix='turtlegit-unified-gutter-') as temporary:
    environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    environment.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),
                       GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0', GIT_OPTIONAL_LOCKS='0')
    for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
        folder = Path(temporary)/str(index); folder.mkdir()
        home = folder/'home'; home.mkdir(mode=0o700)
        private_temp = folder/'temporary'; private_temp.mkdir(mode=0o700)
        repository = folder/'repository'; repository.mkdir()
        environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home), TMPDIR=str(private_temp)+'/', XDG_CONFIG_HOME=str(folder/'xdg'))
        captures = root/'build/qa/udiff-gutter-captures'/hashlib.sha256(str(git.absolute()).encode()).hexdigest()[:10]
        if args.capture_only:
            captures = captures/'capture-only'
        captures.mkdir(parents=True, exist_ok=True)
        print('Checking private Unified Diff gutter with '+str(git), flush=True)
        try:
            result = run_receiver([str(receiver), str(repository), str(git.absolute()), str(captures)] + (['--capture-only'] if args.capture_only else []) + (['--geometry-only'] if args.geometry_only else []),
                                  cwd=root, env=environment, capture_output=True, text=True,
                                  timeout_sample=folder/'timeout.sample.txt')
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if ('PASS Unified Diff gutter geometry only:' if args.geometry_only else 'PASS Unified Diff gutter capture only:' if args.capture_only else 'PASS Unified Diff gutter:') not in result.stdout:
                raise RuntimeError('Gutter receiver exited before final behavioral/cleanup assertions')
        except BaseException:
            evidence = Path(tempfile.mkdtemp(prefix='unified-gutter-failed-'+str(index)+'-', dir=root/'build/qa'))
            shutil.copytree(folder, evidence, dirs_exist_ok=True)
            print('Private failed fixture evidence: '+str(evidence), flush=True)
            raise
