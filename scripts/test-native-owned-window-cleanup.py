#!/usr/bin/env python3
"""Exercise the shared native receiver cleanup with private offscreen windows."""
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-native-cleanup-') as temporary:
    directory = Path(temporary)
    binary = build_receiver(root, [root / 'docs/qa/native-owned-window-cleanup-native-2026-11-25.swift'], directory)
    environment = dict(os.environ, DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'),
                       CFFIXED_USER_HOME=str(directory / 'preferences'), GIT_CONFIG_GLOBAL=os.devnull,
                       GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    result = run_receiver([str(binary)], cwd=root, env=environment, capture_output=True, text=True, timeout=30)
    print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
    if 'PASS: native owned-window cleanup' not in result.stdout:
        raise SystemExit('Native cleanup receiver ended before its assertions completed')
