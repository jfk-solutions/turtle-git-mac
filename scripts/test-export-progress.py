#!/usr/bin/env python3
"""Headless native Export retained results, real ZIP and cancellation checks. No displayed UI or signed acceptance."""
import argparse
import os
from pathlib import Path
import platform
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--receiver', type=Path, default=Path('docs/qa/export-progress-native-2026-10-08.swift'))
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
engines = args.git or [Path('/usr/bin/git')]
for git in engines:
    if not git.is_file() or not os.access(git, os.X_OK):
        parser.error('Git executable missing or not executable: ' + str(git))
if not (root / args.receiver).is_file():
    parser.error('Receiver source missing: ' + str(args.receiver))
products = root / 'build/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='turtlegit-export-progress-native-') as temporary:
    directory = Path(temporary)
    app = root / 'Sources/TurtleGitMac/TurtleGitMacApp.swift'
    copy = directory / app.name
    copy.write_text(app.read_text().replace('@main struct', 'struct', 1))
    sources = sorted(str(p) for p in (root / 'Sources/TurtleGitMac').glob('*.swift') if p != app)
    executable = directory / 'export-progress-native-receiver'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-target', platform.machine() + '-apple-macos13.0', '-I', str(products), '-F', str(products), *sources, str(copy), str(root / args.receiver), '-framework', 'TurtleGitCore', '-o', str(executable)], cwd=root, check=True)
    environment = os.environ.copy()
    environment['DYLD_FRAMEWORK_PATH'] = str(products)
    for index, git in enumerate(engines):
        fixture = directory / ('fixture-' + str(index)); fixture.mkdir()
        print('Checking ' + str(git), flush=True)
        subprocess.run([str(executable), str(fixture), str(git.resolve())], cwd=root, env=environment, check=True)
