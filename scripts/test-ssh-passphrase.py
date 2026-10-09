#!/usr/bin/env python3
"""Verify the native response dialog without displaying or ordering a window."""
import os
from pathlib import Path
import platform
import subprocess
import tempfile
root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='turtlegit-ssh-passphrase-native-') as temporary:
    executable = Path(temporary) / 'ssh-passphrase-native-receiver'
    subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','5','-target',platform.machine()+'-apple-macos13.0','-I',str(products),'-F',str(products),str(root/'Sources/TurtleGitMac/SSHKeyPassphraseWindow.swift'),str(root/'docs/qa/ssh-passphrase-native-2026-10-09.swift'),'-framework','TurtleGitCore','-o',str(executable)],cwd=root,check=True)
    environment = os.environ.copy(); environment['DYLD_FRAMEWORK_PATH'] = str(products)
    subprocess.run([str(executable)],cwd=root,env=environment,check=True)
