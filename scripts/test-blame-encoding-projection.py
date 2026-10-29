#!/usr/bin/env python3
"""Native retained-byte Blame decoding, recovery and owned projection."""
import argparse
import ast
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import tempfile
import time
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
cleanup_tree = ast.parse((root/'scripts/test-log-file-drags.py').read_text())
cleanup = next(item for item in cleanup_tree.body if isinstance(item, ast.FunctionDef) and item.name == 'retire_owned_helpers')
namespace = dict(os=os, signal=signal, time=time, subprocess=subprocess, Path=Path)
exec(compile(ast.Module(body=[cleanup], type_ignores=[]), '<owned Blame encoding projection helper cleanup>', 'exec'), namespace)
retire_owned_helpers = namespace['retire_owned_helpers']
generated = root/'build/qa/blame-encoding-projection-native-sources'
generated.mkdir(parents=True, exist_ok=True)
receiver = build_receiver(root, [root/'docs/qa/blame-encoding-projection-native-2026-10-29.swift'], generated)
results = []
for index, git in enumerate(args.git or [Path('/usr/bin/git'), root/'build/git-runtime/Git/bin/git']):
    git = git.absolute()
    with tempfile.TemporaryDirectory(prefix='turtlegit-blame-encoding-') as temporary:
        folder = Path(temporary)
        for name in ('fixture', 'preferences', 'home', 'temporary', 'xdg'):
            (folder/name).mkdir(mode=0o700)
        config = folder/'global.config'; config.write_text('')
        environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
        environment.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),
                           GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                           CFFIXED_USER_HOME=str(folder/'preferences'),
                           TMPDIR=str(folder/'temporary')+'/', XDG_CONFIG_HOME=str(folder/'xdg'))
        approved = {str(git.resolve())}
        selected = subprocess.run(['/usr/bin/xcrun', '--find', 'git'], capture_output=True, text=True, timeout=10)
        if selected.returncode == 0:
            approved.add(str(Path(selected.stdout.strip()).resolve()))
        passed = False
        print('Checking native Blame encoding projection with '+str(git), flush=True)
        try:
            result = run_receiver([str(receiver), str(folder/'fixture'), str(git)], cwd=root, env=environment,
                                  capture_output=True, text=True, timeout=180, timeout_sample=folder/'timeout.sample.txt')
            print(result.stdout, end=''); print(result.stderr, end='')
            passed = result.returncode == 0 and 'PASS: Blame retained-byte encoding projection' in result.stdout
            results.append(dict(git=str(git), returncode=result.returncode, passed=passed))
            (root/'build/qa/blame-encoding-projection-native-results.json').write_text(json.dumps(results, indent=2)+'\n')
            result.check_returncode()
            if not passed:
                raise RuntimeError('Blame encoding projection receiver exited without its final behavioral/cleanup assertion')
        except BaseException:
            evidence = Path(tempfile.mkdtemp(prefix='blame-encoding-projection-failed-'+str(index)+'-', dir=root/'build/qa'))
            pipes = []
            def ignore_pipes(directory, names):
                omitted = []
                for name in names:
                    candidate = Path(directory)/name
                    if stat.S_ISFIFO(candidate.lstat().st_mode):
                        pipes.append(candidate.relative_to(folder)); omitted.append(name)
                return omitted
            shutil.copytree(folder, evidence, dirs_exist_ok=True, ignore=ignore_pipes)
            for relative in pipes:
                os.mkfifo(evidence/relative, 0o600)
            print('Private failed Blame encoding projection evidence: '+str(evidence), flush=True)
            raise
        finally:
            retired = retire_owned_helpers(folder, approved)
            print('Blame encoding projection owned helper cleanup verified; receiver reaping reported by native_receiver.', flush=True)
            if passed and retired:
                raise RuntimeError('Receiver left owned Git helpers for runner cleanup')
