#!/usr/bin/env python3
"""Headless native Commit Recent messages workflow and owned-sheet lifecycle checks."""
import argparse
import os
from pathlib import Path
import platform
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
engines = [git.resolve() for git in (args.git or [Path('/usr/bin/git')])]
for git in engines:
    if not git.is_file():
        parser.error('Git executable is missing: ' + str(git))
with tempfile.TemporaryDirectory(prefix='turtlegit-commit-history-native-') as temporary:
    directory = Path(temporary)
    app = root / 'Sources/TurtleGitMac/TurtleGitMacApp.swift'
    copy = directory / app.name
    copy.write_text(app.read_text().replace('@main struct', 'struct', 1))
    sources = sorted(str(p) for p in (root / 'Sources/TurtleGitMac').glob('*.swift') if p != app)
    executable = directory / 'commit-history-native-receiver'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-target', platform.machine() + '-apple-macos13.0', '-I', str(products), '-F', str(products), *sources, str(copy), str(root / 'docs/qa/commit-history-native-2026-10-10.swift'), '-framework', 'TurtleGitCore', '-o', str(executable)], cwd=root, check=True)
    environment = os.environ.copy()
    environment['DYLD_FRAMEWORK_PATH'] = str(products)
    for index, git in enumerate(engines):
        fixture = directory / ('fixture-' + str(index)); fixture.mkdir()
        print('Checking ' + str(git), flush=True)
        command = [str(executable), str(fixture), str(git.resolve())]
        result = subprocess.run(command, cwd=root, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        print(result.stdout, end='', flush=True)
        result.check_returncode()
        if 'PASS: Native Commit Recent messages' not in result.stdout:
            raise RuntimeError('Native receiver exited without completing its acceptance checks.')
