#!/usr/bin/env python3
"""Owned hidden Log/Blame/Rebase message-line checks; no main app or physical UI claim."""
import argparse
import os
from pathlib import Path
import platform
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--log-blame-only', action='store_true', help='Focused acceptance; does not verify Rebase rendered text.')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
git_paths = args.git or [Path('/usr/bin/git')]
for git in git_paths:
    if not git.is_file(): parser.error('Git executable does not exist: ' + str(git))
with tempfile.TemporaryDirectory(prefix='turtlegit-message-line-native-') as temporary:
    directory = Path(temporary)
    app = root / 'Sources/TurtleGitMac/TurtleGitMacApp.swift'
    app_copy = directory / app.name
    app_copy.write_text(app.read_text().replace('@main struct', 'struct', 1))
    blame = root / 'Sources/TurtleGitMac/BlameWindow.swift'
    blame_copy = directory / blame.name
    # Same-file test access to the unchanged private production history table.
    blame_copy.write_text(blame.read_text() + '\n@MainActor func messageLineBlameHistoryView(_ model: BlameWindowModel) -> some View { BlameHistoryTable(model: model) }\n')
    sources = sorted(str(p) for p in (root / 'Sources/TurtleGitMac').glob('*.swift') if p not in [app, blame])
    executable = directory / 'message-line-native-receiver'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-target', platform.machine() + '-apple-macos13.0', '-I', str(products), '-F', str(products), *sources, str(app_copy), str(blame_copy), str(root / 'docs/qa/log-message-line-native-2026-10-09.swift'), '-framework', 'TurtleGitCore', '-o', str(executable)], cwd=root, check=True)
    environment = os.environ.copy(); environment['DYLD_FRAMEWORK_PATH'] = str(products)
    for index, git in enumerate(git_paths):
        fixture = directory / ('fixture-' + str(index)); fixture.mkdir()
        print('Checking ' + str(git), flush=True)
        subprocess.run([str(executable), str(fixture), str(git.resolve())] + (['--log-blame-only'] if args.log_blame_only else []), cwd=root, env=environment, check=True)
