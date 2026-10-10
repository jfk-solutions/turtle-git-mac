#!/usr/bin/env python3
"""Headless native Revision Graph interaction and owned-sheet lifecycle checks."""
import argparse
import os
from pathlib import Path
import platform
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--capture-dir', type=Path)
parser.add_argument('--repeat', type=int, default=1, help='Sequential runs per Git engine, reusing one compiled receiver (1–10).')
args = parser.parse_args()
if not 1 <= args.repeat <= 10:
    parser.error('--repeat must be between 1 and 10.')
if args.capture_dir:
    args.capture_dir.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
engines = [git.resolve() for git in (args.git or [Path('/usr/bin/git')])]
for git in engines:
    if not git.is_file():
        parser.error('Git executable is missing: ' + str(git))
with tempfile.TemporaryDirectory(prefix='turtlegit-revision-graph-native-') as temporary:
    directory = Path(temporary)
    app = root / 'Sources/TurtleGitMac/TurtleGitMacApp.swift'
    copy = directory / app.name
    copy.write_text(app.read_text().replace('@main struct', 'struct', 1))
    sources = sorted(str(p) for p in (root / 'Sources/TurtleGitMac').glob('*.swift') if p != app)
    executable = directory / 'revision-graph-native-receiver'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-target', platform.machine() + '-apple-macos13.0', '-I', str(products), '-F', str(products), *sources, str(copy), str(root / 'docs/qa/revision-graph-window-native-2026-10-10.swift'), '-framework', 'TurtleGitCore', '-o', str(executable)], cwd=root, check=True)
    environment = os.environ.copy()
    environment['DYLD_FRAMEWORK_PATH'] = str(products)
    for iteration in range(args.repeat):
        for index, git in enumerate(engines):
            fixture = directory / ('fixture-' + str(iteration) + '-' + str(index)); fixture.mkdir()
            print('Checking ' + str(git) + ' (run ' + str(iteration + 1) + '/' + str(args.repeat) + ')', flush=True)
            command = [str(executable), str(fixture), str(git.resolve()), str(root / 'build/graph-layout-runtime/GraphLayout/graph-layout')]
            if iteration == 0 and index == 0 and args.capture_dir:
                command.append(str(args.capture_dir.resolve()))
            result = subprocess.run(command, cwd=root, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            print(result.stdout, end='', flush=True)
            result.check_returncode()
            if 'PASS: Native Revision Graph' not in result.stdout:
                raise RuntimeError('Native receiver exited without completing its acceptance checks.')
