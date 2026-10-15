#!/usr/bin/env python3
"""Exercise actual AppKit Submodule Update selection events without showing windows."""
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver
ROOT = Path(__file__).resolve().parents[1]
products = ROOT/'build/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='turtlegit-submodule-update-selection-native-') as temporary:
    root = Path(temporary)
    # Exercise the built app, including its title and Help dependencies, rather
    # than maintaining an incomplete duplicate list of production source files.
    receiver = build_receiver(ROOT, [ROOT/'docs/qa/submodule-update-selection-2026-10-10.swift'], root)
    env = os.environ.copy(); env['DYLD_FRAMEWORK_PATH'] = str(products)
    result = run_receiver([str(receiver),str(root)],cwd=ROOT,env=env,check=True,timeout=30,capture_output=True,text=True)
    print(result.stdout,end=''); print(result.stderr,end='')
    if 'literal single submission passed' not in result.stdout:
        raise SystemExit('Submodule selection receiver exited before final assertions.')
assert not Path(temporary).exists()
