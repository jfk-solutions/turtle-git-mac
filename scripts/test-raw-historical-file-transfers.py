#!/usr/bin/env python3
"""Private raw historical individual-file Browser, Log and comparison transfers."""
import argparse
import os
from pathlib import Path
import shutil
import tempfile
from native_receiver import build_receiver, run_receiver
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
sources = root/'build/qa/raw-historical-file-transfers-native-sources'
sources.mkdir(parents=True, exist_ok=True)
receiver = build_receiver(root, [root/'docs/qa/raw-historical-file-transfers-native-2026-10-29.swift'], sources)
for index, git in enumerate(args.git or [Path('/usr/bin/git'), root/'build/git-runtime/Git/bin/git']):
    with tempfile.TemporaryDirectory(prefix='turtlegit-raw-file-transfers-') as temporary:
        folder = Path(temporary)
        for name in ['fixture', 'home', 'temporary', 'xdg']:
            (folder/name).mkdir(mode=0o700)
        (folder/'home/Library/Preferences').mkdir(parents=True, mode=0o700)
        environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
        environment.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull,
                           GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0', HOME=str(folder/'home'),
                           CFFIXED_USER_HOME=str(folder/'home'), TMPDIR=str(folder/'temporary')+'/', XDG_CONFIG_HOME=str(folder/'xdg'))
        print('Checking private raw historical file transfers with '+str(git), flush=True)
        try:
            result = run_receiver([str(receiver), str(folder/'fixture'), str(git.absolute())], cwd=root, env=environment,
                                  capture_output=True, text=True, timeout=180, timeout_sample=folder/'timeout.sample.txt')
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if 'PASS raw historical file transfers:' not in result.stdout:
                raise RuntimeError('Raw transfer receiver exited before final assertions/cleanup')
        except BaseException:
            evidence = Path(tempfile.mkdtemp(prefix='raw-historical-file-transfers-failed-'+str(index)+'-', dir=root/'build/qa'))
            shutil.copytree(folder, evidence, dirs_exist_ok=True)
            print('Private failed fixture evidence: '+str(evidence), flush=True)
            raise
