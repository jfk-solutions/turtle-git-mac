#!/usr/bin/env python3
"""Native Compare/three-way Reload position, fresh navigation and ownership family."""
import argparse
import json
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['compare', 'three-way'], action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
qa = root / 'build/qa'
qa.mkdir(parents=True, exist_ok=True)
cases = [('compare', 'compare-reload-position-native-2026-11-25.swift'),
         ('three-way', 'three-way-reload-position-native-2026-11-25.swift')]
results = []
for name, source in cases:
    if args.only and name not in args.only:
        continue
    sources = qa / ('editor-reload-' + name + '-sources')
    sources.mkdir(parents=True, exist_ok=True)
    receiver = build_receiver(root, [root / 'docs/qa' / source], sources)
    for index, git in enumerate(args.git or [Path('/usr/bin/git'), root / 'build/git-runtime/Git/bin/git']):
        with tempfile.TemporaryDirectory(prefix='turtlegit-editor-reload-' + name + '-') as temporary:
            context = Path(temporary)
            fixture = context / 'fixture'
            fixture.mkdir()
            home = context / 'home'; home.mkdir(mode=0o700)
            scratch = context / 'temporary'; scratch.mkdir(mode=0o700)
            config = context / 'global.config'; config.write_text('')
            env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
            env.update(HOME=str(home), CFFIXED_USER_HOME=str(home), TMPDIR=str(scratch) + '/',
                       XDG_CONFIG_HOME=str(context / 'xdg'), GIT_CONFIG_GLOBAL=str(config),
                       GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                       DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'))
            print('Checking editor Reload ' + name + ' with ' + str(git), flush=True)
            result = run_receiver([str(receiver), str(fixture), str(git.absolute())], cwd=root,
                                  env=env, capture_output=True, text=True,
                                  timeout_sample=qa / ('editor-reload-' + name + '-' + str(index) + '-' + context.name + '.sample.txt'))
            print(result.stdout, end=''); print(result.stderr, end='')
            passed = result.returncode == 0 and 'PASS editor Reload ' + name in result.stdout
            results.append(dict(case=name, git=str(git.absolute()), returncode=result.returncode, passed=passed))
            (qa / 'editor-reload-position-results.json').write_text(json.dumps(results, indent=2) + '\n')
            result.check_returncode()
            if not passed:
                raise SystemExit('Native Reload receiver exited before completion')
