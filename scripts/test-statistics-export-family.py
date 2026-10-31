#!/usr/bin/env python3
"""Focused private native Statistics save filters, captured choices and ownership."""
import argparse
import json
import os
import shutil
from pathlib import Path
import tempfile

from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['formats', 'selection', 'ownership'], action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
cache = root / 'build/qa/statistics-export-family-native-sources'
cache.mkdir(parents=True, exist_ok=True)
receiver = build_receiver(root, [root / 'docs/qa/statistics-export-family-native-2026-10-21.swift'], cache)
results = []
for git in args.git or [Path('/usr/bin/git'), root / 'build/git-runtime/Git/bin/git']:
    for case in args.only or ['formats', 'selection', 'ownership']:
        with tempfile.TemporaryDirectory(prefix='turtlegit-statistics-export-' + case + '-') as temporary:
            context = Path(temporary)
            fixture = context / 'fixture'
            preferences = context / 'preferences'
            xdg = context / 'xdg'
            scratch = context / 'temporary'
            home=context/'home'
            for directory in [fixture, preferences, xdg, scratch, home]:
                directory.mkdir(mode=0o700)
            config = context / 'global.config'
            config.write_text('')
            environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
            environment.update(GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                               HOME=str(home), CFFIXED_USER_HOME=str(preferences), XDG_CONFIG_HOME=str(xdg), TMPDIR=str(scratch) + '/',
                               DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'))
            print('Checking Statistics export ' + case + ' with ' + str(git), flush=True)
            result=None
            try:
                result = run_receiver([str(receiver), str(fixture), str(git.absolute()), case],
                                      cwd=root, env=environment, capture_output=True, text=True,
                                      timeout_sample=context / 'timeout.sample.txt')
                print(result.stdout, end='')
                print(result.stderr, end='')
                passed = result.returncode == 0 and 'PASS: Statistics export family ' + case in result.stdout
                results.append(dict(git=str(git.absolute()), case=case, returncode=result.returncode, passed=passed))
                (root / 'build/qa/statistics-export-family-native-results.json').write_text(json.dumps(results, indent=2) + '\n')
                result.check_returncode()
                if not passed:
                    raise SystemExit('Statistics export receiver exited before completion')
            except BaseException as error:
                evidence=Path(tempfile.mkdtemp(prefix='statistics-export-failed-'+case+'-',dir=root/'build/qa'))
                shutil.copytree(context,evidence,dirs_exist_ok=True)
                for stream in ['stdout','stderr']:
                    payload=getattr(error,stream,None) or (getattr(result,stream,None) if result is not None else None)
                    if payload is not None:
                        (evidence/(stream+'.log')).write_text(payload.decode('utf-8',errors='replace') if isinstance(payload,bytes) else str(payload))
                (evidence/'failure.json').write_text(json.dumps(dict(git=str(git.absolute()),case=case,error_type=type(error).__name__,error=str(error)),indent=2)+'\n')
                print('Retained Statistics export phase/sample/private fixture: '+str(evidence),flush=True)
                raise
