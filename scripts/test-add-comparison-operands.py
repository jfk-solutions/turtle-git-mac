#!/usr/bin/env python3
"""Add explicit comparison family; actual native menu and accepted Root operands."""
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
parser.add_argument('--only', choices=('operands', 'primary', 'stale', 'ownership', 'native-warning', 'legacy'), action='append')
parser.add_argument('--results', type=Path, help='Optional JSON receipt destination; defaults to build/qa')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
cleanup_tree = ast.parse((root/'scripts/test-log-file-drags.py').read_text())
cleanup = next(item for item in cleanup_tree.body if isinstance(item, ast.FunctionDef) and item.name == 'retire_owned_helpers')
namespace = dict(os=os, signal=signal, time=time, subprocess=subprocess, Path=Path)
exec(compile(ast.Module(body=[cleanup], type_ignores=[]), '<owned Add operand helper cleanup>', 'exec'), namespace)
retire_owned_helpers = namespace['retire_owned_helpers']
generated = root/'build/qa/add-comparison-operands-native-sources'
generated.mkdir(parents=True, exist_ok=True)
receiver = build_receiver(root, [root/'docs/qa/add-comparison-operands-native-2026-11-23.swift'], generated)
results = []
receipt = args.results or root/'build/qa/add-comparison-operands-results.json'
receipt.parent.mkdir(parents=True, exist_ok=True)
for index, git in enumerate(args.git or [Path('/usr/bin/git'), root/'build/git-runtime/Git/bin/git']):
    git = git.absolute()
    with tempfile.TemporaryDirectory(prefix='turtlegit-add-operands-') as temporary:
        folder = Path(temporary)
        for name in ('repository', 'preferences', 'home', 'temporary', 'xdg'):
            (folder/name).mkdir(mode=0o700)
        config = folder/'global.config'; config.write_text('')
        environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
        environment.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),
                           GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                           HOME=str(folder/'home'), CFFIXED_USER_HOME=str(folder/'preferences'),
                           TMPDIR=str(folder/'temporary')+'/', XDG_CONFIG_HOME=str(folder/'xdg'))
        approved = {str(git.resolve())}
        selected = subprocess.run(['/usr/bin/xcrun', '--find', 'git'], capture_output=True, text=True, timeout=10)
        if selected.returncode == 0:
            approved.add(str(Path(selected.stdout.strip()).resolve()))
        passed = False
        print('Checking Add comparison operands with '+str(git), flush=True)
        started = time.monotonic()
        try:
            result = run_receiver([str(receiver), str(folder/'repository'), str(git), *(args.only or [])], cwd=root, env=environment,
                                  capture_output=True, text=True, timeout=240, timeout_sample=folder/'timeout.sample.txt')
            print(result.stdout, end=''); print(result.stderr, end='')
            (root/'build/qa'/('add-comparison-operands-'+str(index)+'.log')).write_text(result.stdout+result.stderr)
            passed = result.returncode == 0 and 'PASS: Add explicit comparison operands' in result.stdout
            results.append(dict(git=str(git), returncode=result.returncode, passed=passed, cohorts=args.only or ['all'], seconds=round(time.monotonic()-started, 3)))
            receipt.write_text(json.dumps(results, indent=2)+'\n')
            result.check_returncode()
            if not passed:
                raise RuntimeError('Add operand receiver exited before its final behavioral/cleanup assertion')
        except BaseException:
            evidence = Path(tempfile.mkdtemp(prefix='add-operands-failed-'+str(index)+'-', dir=root/'build/qa'))
            shutil.copytree(folder, evidence, dirs_exist_ok=True, symlinks=True)
            print('Private failed Add operand evidence: '+str(evidence), flush=True)
            raise
        finally:
            retired = retire_owned_helpers(folder, approved)
            if passed and retired:
                raise RuntimeError('Add operand receiver left an owned Git process')
            print('Add operand receiver and owned helper cleanup completed.', flush=True)
