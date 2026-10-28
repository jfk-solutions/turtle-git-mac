#!/usr/bin/env python3
"""Grouped native Log working-tree LFS family against private real-Git stubs."""
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
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
# Reuse the existing strict executable-plus-private-resource ownership verifier.
# Do not execute that driver's top-level CLI or change its checked fixture.
tree = ast.parse((root/'scripts/test-log-file-drags.py').read_text())
function = next(item for item in tree.body if isinstance(item, ast.FunctionDef) and item.name == 'retire_owned_helpers')
namespace = dict(os=os, signal=signal, time=time, subprocess=subprocess, Path=Path)
exec(compile(ast.Module(body=[function], type_ignores=[]), '<owned private LFS cleanup>', 'exec'), namespace)
retire_owned_helpers = namespace['retire_owned_helpers']
source = root/'docs/qa/log-working-lfs-native-2026-10-28.swift'
generated = root/'build/qa/log-working-lfs-native-sources'
generated.mkdir(parents=True, exist_ok=True)
receiver = build_receiver(root, [source], generated)
results = []
engines = args.git or [Path('/usr/bin/git'), root/'build/git-runtime/Git/bin/git']
for index, engine in enumerate(engines):
    engine = engine.absolute()
    with tempfile.TemporaryDirectory(prefix='turtlegit-log-lfs-') as temporary:
        context = Path(temporary)
        for name in ['fixture', 'preferences', 'xdg', 'temporary', 'home']:
            (context/name).mkdir(mode=0o700)
        config = context/'global.config'
        config.write_text('')
        environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
        environment.update(GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                           HOME=str(context/'home'), CFFIXED_USER_HOME=str(context/'preferences'),
                           XDG_CONFIG_HOME=str(context/'xdg'), TMPDIR=str(context/'temporary')+'/',
                           DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'))
        approved = {str(engine.resolve())}
        python = subprocess.run(['/usr/bin/python3', '-c', 'import os,sys; print(os.path.realpath(sys.executable))'],
                                capture_output=True, text=True, check=True, timeout=10)
        approved.add(python.stdout.strip())
        selected = subprocess.run(['/usr/bin/xcrun', '--find', 'git'], capture_output=True, text=True, timeout=10)
        if selected.returncode == 0:
            approved.add(str(Path(selected.stdout.strip()).resolve()))
        passed = False
        print('Checking native Log working-tree LFS with '+str(engine), flush=True)
        try:
            result = run_receiver([str(receiver), str(context/'fixture'), str(engine)], cwd=root,
                                  env=environment, capture_output=True, text=True, timeout=180,
                                  timeout_sample=context/'timeout.sample.txt')
            print(result.stdout, end='')
            print(result.stderr, end='')
            passed = result.returncode == 0 and 'PASS: Log working-tree LFS' in result.stdout
            results.append(dict(git=str(engine), returncode=result.returncode, passed=passed))
            (root/'build/qa/log-working-lfs-native-results.json').write_text(json.dumps(results, indent=2)+'\n')
            result.check_returncode()
            if not passed:
                raise RuntimeError('Owned Log LFS receiver exited without its final assertion receipt')
        finally:
            sample = context/'timeout.sample.txt'
            if sample.is_file():
                shutil.copy2(sample, root/('build/qa/log-working-lfs-'+str(index)+'-timeout.sample.txt'))
            cleanup_needed = retire_owned_helpers(context, approved)
            print('Owned Log LFS helper cleanup verified; receiver reaping reported by native_receiver.', flush=True)
            if passed and cleanup_needed:
                raise RuntimeError('Successful Log LFS receiver left owned helper processes running')
