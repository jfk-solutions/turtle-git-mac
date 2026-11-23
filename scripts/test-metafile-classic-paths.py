#!/usr/bin/env python3
"""Native classic EMF construction/replacement consumer and ownership family."""
import argparse
import ast
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=('consumers', 'ownership'), action='append')
parser.add_argument('--results', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
scope = dict(os=os, signal=signal, time=time, subprocess=subprocess, Path=Path)
source = ast.parse((root/'scripts/test-metafile-workflows.py').read_text())
cleanup = next(node for node in source.body if isinstance(node, ast.FunctionDef) and node.name == 'retire_owned_helpers')
exec(compile(ast.Module(body=[cleanup], type_ignores=[]), '<owned classic path cleanup>', 'exec'), scope)
retire_owned_helpers = scope['retire_owned_helpers']
generated = root/'build/qa/metafile-classic-path-native-sources'; generated.mkdir(parents=True, exist_ok=True)
receiver = build_receiver(root, [root/'docs/qa/metafile-classic-paths-native-2026-11-23.swift'], generated)
results = []
receipt = args.results or root/'build/qa/metafile-classic-path-native-results.json'
receipt.parent.mkdir(parents=True, exist_ok=True)
corpus = root/'Tests/TurtleGitCoreTests/Fixtures/Metafile/ClassicPaths'
for index, git in enumerate(args.git or [Path('/usr/bin/git'), root/'build/git-runtime/Git/bin/git']):
    git = git.absolute()
    with tempfile.TemporaryDirectory(prefix='turtlegit-classic-paths-') as name:
        folder = Path(name)
        for child in ('repository', 'home', 'preferences', 'temporary', 'xdg'):
            (folder/child).mkdir(mode=0o700)
        config = folder/'global.config'; config.write_text('')
        environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
        environment.update(HOME=str(folder/'home'), CFFIXED_USER_HOME=str(folder/'preferences'), TMPDIR=str(folder/'temporary')+'/',
                           XDG_CONFIG_HOME=str(folder/'xdg'), GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                           DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'))
        approved = {str(git.resolve()), str((root/'build/metafile-runtime/Metafile/metafile-convert').resolve())}
        passed = False
        started = time.monotonic()
        try:
            result = run_receiver([str(receiver), str(folder/'repository'), str(git), str(corpus), *(args.only or [])], cwd=root, env=environment,
                                  capture_output=True, text=True, timeout=240, timeout_sample=folder/'timeout.sample.txt')
            print(result.stdout, end=''); print(result.stderr, end='')
            (root/'build/qa'/('metafile-classic-path-'+str(index)+'.log')).write_text(result.stdout+result.stderr)
            passed = result.returncode == 0 and 'PASS: Classic EMF typed paths' in result.stdout
            results.append(dict(git=str(git), returncode=result.returncode, passed=passed, cohorts=args.only or ['consumers', 'ownership'], seconds=round(time.monotonic()-started, 3)))
            receipt.write_text(json.dumps(results, indent=2)+'\n')
            result.check_returncode()
            if not passed:
                raise RuntimeError('Classic path receiver did not reach its behavioral and ownership conclusion')
        except BaseException:
            evidence = Path(tempfile.mkdtemp(prefix='classic-paths-failed-'+str(index)+'-', dir=root/'build/qa'))
            shutil.copytree(folder, evidence, dirs_exist_ok=True, symlinks=True)
            print('Retained private classic path failure: '+str(evidence), flush=True)
            raise
        finally:
            needed = retire_owned_helpers(folder, approved)
            if passed and needed:
                raise RuntimeError('Owned classic path helper outlived the completed receiver')
            print('Owned classic path receiver/helper cleanup completed.', flush=True)
