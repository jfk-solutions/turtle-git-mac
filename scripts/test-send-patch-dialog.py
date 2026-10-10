#!/usr/bin/env python3
"""Hidden native Send Patch dialog/model verification. No mail client or sending."""
from pathlib import Path
import os
import platform
import subprocess
import tempfile
root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='turtlegit-send-patch-dialog-native-') as temporary:
    directory = Path(temporary)
    app = root / 'Sources/TurtleGitMac/TurtleGitMacApp.swift'
    copy = directory / app.name
    copy.write_text(app.read_text().replace('@main struct', 'struct', 1))
    sources = sorted(str(p) for p in (root / 'Sources/TurtleGitMac').glob('*.swift') if p != app)
    executable = directory / 'send-patch-dialog-native-receiver'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-target', platform.machine() + '-apple-macos13.0', '-I', str(products), '-F', str(products), *sources, str(copy), str(root / 'docs/qa/send-patch-dialog-native-2026-10-10.swift'), '-framework', 'TurtleGitCore', '-o', str(executable)], cwd=root, check=True)
    fixture = directory / 'fixture'; fixture.mkdir()
    environment = os.environ.copy(); environment['DYLD_FRAMEWORK_PATH'] = str(products)
    subprocess.run([str(executable), str(fixture)], cwd=root, env=environment, check=True)
