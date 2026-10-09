#!/usr/bin/env python3
"""Exercise actual AppKit Submodule Update selection events without showing windows."""
import os
from pathlib import Path
import platform
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
products = ROOT/'build/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='turtlegit-submodule-update-selection-native-') as temporary:
    root = Path(temporary); receiver = root/'receiver'
    sources = ['SubmoduleUpdateWindow.swift','SubmoduleUpdatePathList.swift','SelectionAllCheckbox.swift','DialogGeometry.swift','CommandLabel.swift']
    subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','5','-target',platform.machine()+'-apple-macos13.0','-I',products,'-F',products,*[ROOT/'Sources/TurtleGitMac'/p for p in sources],ROOT/'docs/qa/submodule-update-selection-2026-10-10.swift','-framework','TurtleGitCore','-o',receiver],check=True)
    env = os.environ.copy(); env['DYLD_FRAMEWORK_PATH'] = str(products)
    subprocess.run([receiver,root],env=env,check=True,timeout=30)
assert not Path(temporary).exists()
