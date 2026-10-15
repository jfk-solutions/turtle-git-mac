#!/usr/bin/env python3
"""Hidden native submodule progress output and native controls; private clipboard/preferences."""
from native_receiver import build_receiver, run_receiver
import os
from pathlib import Path
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
products = root/'build/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='turtlegit-submodule-progress-output-native-') as temporary:
    directory = Path(temporary)
    executable = build_receiver(root, [root / 'docs/qa/submodule-progress-output-native-2026-10-09.swift'], directory)
    environment = os.environ.copy(); environment['DYLD_FRAMEWORK_PATH'] = str(products)
    run_receiver([str(executable)],cwd=root,env=environment,check=True)
