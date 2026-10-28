#!/usr/bin/env python3
"""Native Commit Git Gui tables, captured stage/unstage adapter and double-action hookup and owned loading."""
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
cleanup_tree = ast.parse((root/'scripts/test-log-file-drags.py').read_text())
cleanup = next(item for item in cleanup_tree.body if isinstance(item, ast.FunctionDef) and item.name == 'retire_owned_helpers')
namespace = dict(os=os, signal=signal, time=time, subprocess=subprocess, Path=Path)
exec(compile(ast.Module(body=[cleanup], type_ignores=[]), '<owned GUI staging helper cleanup>', 'exec'), namespace)
retire_owned_helpers = namespace['retire_owned_helpers']
generated = root/'build/qa/commit-gui-staging-native-sources'
generated.mkdir(parents=True, exist_ok=True)
receiver = build_receiver(root, [root/'docs/qa/commit-gui-staging-native-2026-10-28.swift'], generated)
results = []
for index, git in enumerate(args.git or [Path('/usr/bin/git'), root/'build/git-runtime/Git/bin/git']):
    git = git.absolute()
    with tempfile.TemporaryDirectory(prefix='turtlegit-commit-gui-') as temporary:
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
        print('Checking native Commit Git Gui staging with '+str(git), flush=True)
        try:
            result = run_receiver([str(receiver), str(folder/'repository'), str(git)], cwd=root, env=environment,
                                  capture_output=True, text=True, timeout=180, timeout_sample=folder/'timeout.sample.txt')
            print(result.stdout, end=''); print(result.stderr, end='')
            passed = result.returncode == 0 and 'PASS: Commit GUI staging native tables' in result.stdout
            results.append(dict(git=str(git), returncode=result.returncode, passed=passed))
            (root/'build/qa/commit-gui-staging-native-results.json').write_text(json.dumps(results, indent=2)+'\n')
            result.check_returncode()
            if not passed:
                raise RuntimeError('GUI staging receiver exited without its final behavioral/cleanup assertion')
            destination = root/'build/qa/commit-gui-staging-captures'/str(index)
            destination.mkdir(parents=True, exist_ok=True)
            for image in (folder/'repository').glob('commit-gui-*.png'):
                shutil.copy2(image, destination/image.name)
        except BaseException:
            evidence = Path(tempfile.mkdtemp(prefix='commit-gui-staging-failed-'+str(index)+'-', dir=root/'build/qa'))
            shutil.copytree(folder, evidence, dirs_exist_ok=True)
            print('Private failed GUI staging evidence: '+str(evidence), flush=True)
            raise
        finally:
            retired = retire_owned_helpers(folder, approved)
            print('GUI staging owned helper cleanup verified; receiver reaping reported by native_receiver.', flush=True)
            if passed and retired:
                raise RuntimeError('Receiver left owned Git helpers for runner cleanup')
