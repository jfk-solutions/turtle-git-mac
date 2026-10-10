#!/usr/bin/env python3
"""Hidden native Email settings QA; private preferences and simulated Keychain only."""
from pathlib import Path
import os
import platform
import subprocess
import tempfile
root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='turtlegit-email-settings-native-') as temporary:
    executable = Path(temporary) / 'email-settings-native-receiver'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5',
                    '-target', platform.machine() + '-apple-macos13.0',
                    '-I', str(products), '-F', str(products),
                    str(root / 'Sources/TurtleGitMac/EmailSettings.swift'),
                    str(root / 'docs/qa/email-settings-native-2026-10-10.swift'),
                    '-framework', 'TurtleGitCore', '-o', str(executable)], cwd=root, check=True)
    environment = os.environ.copy(); environment['DYLD_FRAMEWORK_PATH'] = str(products)
    subprocess.run([str(executable)], cwd=root, env=environment, check=True)
