#!/usr/bin/env python3
"""Headless native Cherry Pick check; requires Debug framework and SwiftPM editor builds.

This hosts real views without displayed windows. It does not verify signed
sandbox execution, displayed alerts, screenshots or keyboard/accessibility.
"""
import argparse
import os
import platform
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append', help='Git to test; may be repeated (default: /usr/bin/git).')
focus = parser.add_mutually_exclusive_group()
focus.add_argument("--references-only", action="store_true", help="Run only native Rebase reference-update fixtures.")
focus.add_argument("--menus-only", action="store_true", help="Run only native Rebase revision-menu fixtures.")
focus.add_argument("--commit-selection-only", action="store_true", help="Run only native Commit visible-selection and full-index fixtures.")
focus.add_argument("--log-paths-only", action="store_true", help="Run only native Log path/filter/status-color fixtures.")
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
editor = root / '.build/debug/TurtleGitMac'
if not (products / 'TurtleGitCore.framework').is_dir() or not editor.is_file():
    parser.error('Build the unsigned Debug Xcode product and swift build first.')
git_paths = args.git or [Path('/usr/bin/git')]
for git in git_paths:
    if not git.resolve().is_file():
        parser.error('Git executable does not exist.')
with tempfile.TemporaryDirectory(prefix='turtlegit-cherry-pick-check-') as temporary:
    directory = Path(temporary)
    app_source = root / 'Sources/TurtleGitMac/TurtleGitMacApp.swift'
    app_copy = directory / app_source.name
    app_copy.write_text(app_source.read_text().replace('@main struct', 'struct', 1))
    sources = sorted(str(p) for p in (root / 'Sources/TurtleGitMac').glob('*.swift') if p != app_source)
    receiver = root / 'docs/qa/cherry-pick-native-receiver-2026-10-06.swift'
    executable = directory / 'cherry-pick-native-receiver'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-name', 'TurtleGitMac',
                    '-enable-testing', '-swift-version', '5', '-target', platform.machine() + '-apple-macos13.0',
                    '-I', str(products), '-F', str(products), *sources, str(app_copy), str(receiver),
                    '-framework', 'TurtleGitCore', '-o', str(executable)], cwd=root, check=True)
    environment = os.environ.copy()
    environment['DYLD_FRAMEWORK_PATH'] = str(products)
    if args.references_only:
        environment['TURTLEGIT_NATIVE_REFERENCE_ONLY'] = '1'
    else:
        environment.pop('TURTLEGIT_NATIVE_REFERENCE_ONLY', None)
    if args.menus_only:
        environment['TURTLEGIT_NATIVE_MENUS_ONLY'] = '1'
    else:
        environment.pop('TURTLEGIT_NATIVE_MENUS_ONLY', None)
    if args.commit_selection_only:
        environment["TURTLEGIT_NATIVE_COMMIT_SELECTION_ONLY"] = "1"
    else:
        environment.pop("TURTLEGIT_NATIVE_COMMIT_SELECTION_ONLY", None)
    environment["TURTLEGIT_NATIVE_LOG_PATHS_ONLY"] = "1" if args.log_paths_only else "0"
    for git in git_paths:
        print('Checking Git: ' + str(git.resolve()), flush=True)
        environment['TURTLEGIT_TEST_GIT'] = str(git.resolve())
        subprocess.run([str(executable)], cwd=root, env=environment, check=True)
