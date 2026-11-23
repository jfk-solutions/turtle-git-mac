#!/usr/bin/env python3
"""Scoped Add/Revert literal Git reads, immutable Retry scope and cancellation ownership."""
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
parser.add_argument('--only', choices=('add', 'revert', 'rescope-cancel', 'commit'), action='append', help='Run only selected connected cohorts; default runs all')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
cleanup_tree = ast.parse((root/'scripts/test-log-file-drags.py').read_text())
cleanup = next(item for item in cleanup_tree.body if isinstance(item, ast.FunctionDef) and item.name == 'retire_owned_helpers')
namespace = dict(os=os, signal=signal, time=time, subprocess=subprocess, Path=Path)
exec(compile(ast.Module(body=[cleanup], type_ignores=[]), '<owned scoped read helper cleanup>', 'exec'), namespace)
retire_owned_helpers = namespace['retire_owned_helpers']
generated = root/'build/qa/scoped-working-reads-native-sources'
generated.mkdir(parents=True, exist_ok=True)
# Reuse the actual retained native input/projection helpers, without coupling
# this cohort to the old driver's unrelated @main continuation dependencies.
original = (root/'docs/qa/status-primary-activation-native-2026-10-30.swift').read_text()
boundary = '    static func main()async throws {'
if original.count(boundary) != 1:
    raise SystemExit('Primary helper entry changed; inspect before copying helpers')
helper = generated/'ScopedWorkingPrimaryHelpers.swift'
helper.write_text(original[:original.index(boundary)].replace('@main ', '', 1)+'}\n')
sources = [helper, root/'docs/qa/scoped-working-reads-native-2026-11-23.swift']
receiver = build_receiver(root, sources, generated)
results = []
for index, git in enumerate(args.git or [Path('/usr/bin/git'), root/'build/git-runtime/Git/bin/git']):
    git = git.absolute()
    with tempfile.TemporaryDirectory(prefix='turtlegit-scoped-reads-') as temporary:
        folder = Path(temporary)
        for name in ('fixture', 'preferences', 'home', 'temporary', 'xdg'):
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
        print('Checking scoped Add/Revert reads with '+str(git), flush=True)
        try:
            result = run_receiver([str(receiver), str(folder/'fixture'), str(git), *(args.only or [])], cwd=root, env=environment,
                                  capture_output=True, text=True, timeout=240, timeout_sample=folder/'timeout.sample.txt')
            print(result.stdout, end=''); print(result.stderr, end='')
            passed = result.returncode == 0 and 'PASS: Scoped Add/Revert native reads' in result.stdout
            results.append(dict(git=str(git), returncode=result.returncode, passed=passed, cohorts=args.only or ['all']))
            (root/'build/qa/scoped-working-reads-results.json').write_text(json.dumps(results, indent=2)+'\n')
            receipt_folder = root/'build/qa/scoped-working-reads-receipts'/str(index)
            receipt_folder.mkdir(parents=True, exist_ok=True)
            for receipt in (folder/'fixture').glob('*-argv.json'):
                shutil.copy2(receipt, receipt_folder/receipt.name)
            result.check_returncode()
            if not passed:
                raise RuntimeError('Scoped read receiver exited before its final behavioral/cleanup assertion')
        except BaseException:
            evidence = Path(tempfile.mkdtemp(prefix='scoped-working-reads-failed-'+str(index)+'-', dir=root/'build/qa'))
            shutil.copytree(folder, evidence, dirs_exist_ok=True, symlinks=True)
            print('Private failed scoped read evidence: '+str(evidence), flush=True)
            raise
        finally:
            retired = retire_owned_helpers(folder, approved)
            if passed and retired:
                raise RuntimeError('Scoped read receiver left an owned Git process')
            print('Scoped read receiver and owned helper cleanup completed.', flush=True)
