#!/usr/bin/env python3
"""Grouped optional commit workspace and curved comparison receiver checks."""
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

root = Path(__file__).resolve().parent.parent
sources = root / 'build/qa/interface-options-native-sources'
sources.mkdir(parents=True, exist_ok=True)
fixture = root / 'docs/qa/interface-options-native-2026-10-24.swift'
receiver = build_receiver(root, [fixture], sources)
with tempfile.TemporaryDirectory(prefix='turtlegit-interface-options-') as temporary:
    folder = Path(temporary)
    private_temporary = folder / 'temporary'
    private_temporary.mkdir(mode=0o700)
    environment = dict(os.environ, TMPDIR=str(private_temporary)+'/', GIT_CONFIG_GLOBAL=os.devnull,
                       GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0', XDG_CONFIG_HOME=str(folder/'xdg'))
    for key in ['GIT_CONFIG_PARAMETERS', 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_AUTHOR_DATE',
                'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL', 'GIT_COMMITTER_DATE']:
        environment.pop(key, None)
    result = run_receiver([str(receiver), str(folder)], cwd=root, env=environment,
                          capture_output=True, text=True, timeout_sample=folder/'timeout.sample.txt')
    print(result.stdout, end='')
    print(result.stderr, end='')
    result.check_returncode()
    if 'PASS interface options' not in result.stdout:
        raise SystemExit('Receiver exited before completion')
