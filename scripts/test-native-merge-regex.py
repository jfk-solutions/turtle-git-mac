#!/usr/bin/env python3
"""One compilation and one focused native regex receiver; no installed app."""
from pathlib import Path
import os
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='turtlegit-merge-regex-native-') as temporary:
    folder = Path(temporary)
    app = root / 'Sources/TurtleGitMac/TurtleGitMacApp.swift'
    copy = folder / app.name
    copy.write_text(app.read_text().replace('@main struct', 'struct', 1))
    sources = sorted(str(p) for p in (root / 'Sources/TurtleGitMac').glob('*.swift') if p != app)
    executable = folder / 'merge-regex-native-receiver'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-whole-module-optimization', '-Onone',
                    '-target', platform.machine() + '-apple-macos13.0', '-I', str(products), '-F', str(products),
                    *sources, str(copy), str(root / 'docs/qa/merge-regex-native-2026-10-12.swift'),
                    '-framework', 'TurtleGitCore', '-o', str(executable)], cwd=root, check=True)
    environment = os.environ.copy(); environment['DYLD_FRAMEWORK_PATH'] = str(products)
    subprocess.run([str(executable), str(products / 'TurtleGitMac.app/Contents/Helpers/IssueRegex/issue-regex')],
                   cwd=root, env=environment, check=True, timeout=60)
