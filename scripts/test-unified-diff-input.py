#!/usr/bin/env python3
"""Owned standalone stdin input, raw document publication and real worker drain."""
import argparse
import json
import os
from pathlib import Path
import shutil
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--only', action='append', choices=['stream', 'lifetime', 'failure', 'command', 'startup'])
args = parser.parse_args()
root = next(p for p in Path(__file__).resolve().parents if (p / 'Sources/TurtleGitMac').is_dir())
generated = root / 'build/qa/unified-diff-input-native-sources'
generated.mkdir(parents=True, exist_ok=True)
receiver = build_receiver(root, [root / 'docs/qa/unified-diff-input-native-2026-10-25.swift'], generated)
results = []
# No Git executable or repository is used: the actual standalone controller is
# intentionally initialized with only its private document directory.
for case in args.only or ['stream', 'lifetime', 'failure', 'command', 'startup']:
    with tempfile.TemporaryDirectory(prefix='turtlegit-unified-input-' + case + '-') as temporary:
        context = Path(temporary)
        for name in ['fixture', 'preferences', 'home', 'xdg', 'temporary']:
            (context / name).mkdir(mode=0o700)
        config = context / 'global.config'
        config.write_text('')
        env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
        env.update(HOME=str(context / 'home'), CFFIXED_USER_HOME=str(context / 'preferences'),
                   XDG_CONFIG_HOME=str(context / 'xdg'), TMPDIR=str(context / 'temporary') + '/',
                   GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                   DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'))
        print('Checking unified diff input ' + case, flush=True)
        sample = context / 'timeout.sample.txt'
        try:
            result = run_receiver([str(receiver), str(context / 'fixture'), 'no-git', case],
                                  cwd=root, env=env, capture_output=True, text=True,
                                  timeout_sample=sample)
            print(result.stdout, end='')
            print(result.stderr, end='')
            passed = result.returncode == 0 and 'PASS: unified diff input ' + case in result.stdout
            results.append(dict(case=case, returncode=result.returncode, passed=passed))
            (root / 'build/qa/unified-diff-input-native-results.json').write_text(json.dumps(results, indent=2) + '\n')
            result.check_returncode()
            if not passed:
                raise RuntimeError('Unified Diff input receiver exited without completion')
        finally:
            if sample.is_file():
                shutil.copy2(sample, root / ('build/qa/unified-diff-input-' + case + '-timeout.sample.txt'))
