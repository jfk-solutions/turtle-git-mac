#!/usr/bin/env python3
"""One compilation and one focused native regex receiver; no installed app."""
from pathlib import Path
import os
import argparse
import platform
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--three-pane', action='store_true')
parser.add_argument('--two-pane', action='store_true')
parser.add_argument('--options-batch', action='store_true')
parser.add_argument('--screenshots', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='turtlegit-merge-regex-native-') as temporary:
    folder = Path(temporary)
    app = root / 'Sources/TurtleGitMac/TurtleGitMacApp.swift'
    copy = folder / app.name
    copy.write_text(app.read_text().replace('@main struct', 'struct', 1))
    sources = sorted(str(p) for p in (root / 'Sources/TurtleGitMac').glob('*.swift') if p != app)
    additional = []
    if args.options_batch:
        for name in ['three-pane-engine-native-2026-10-12.swift', 'two-pane-engine-native-2026-10-12.swift', 'merge-locator-native-2026-10-12.swift']:
            receiver = folder / name
            receiver.write_text((root / 'docs/qa' / name).read_text().replace('@main struct', 'struct', 1))
            additional.append(str(receiver))
    executable = folder / 'merge-regex-native-receiver'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-whole-module-optimization', '-Onone',
                    '-target', platform.machine() + '-apple-macos13.0', '-I', str(products), '-F', str(products),
                    *sources, str(copy), *additional, str(root / ('docs/qa/comparison-options-native-2026-10-12.swift' if args.options_batch else 'docs/qa/two-pane-engine-native-2026-10-12.swift' if args.two_pane else 'docs/qa/three-pane-engine-native-2026-10-12.swift' if args.three_pane else 'docs/qa/merge-regex-native-2026-10-12.swift')),
                    '-framework', 'TurtleGitCore', '-o', str(executable)], cwd=root, check=True)
    environment = os.environ.copy(); environment['DYLD_FRAMEWORK_PATH'] = str(products)
    helper = products / 'TurtleGitMac.app/Contents/Helpers'
    arguments = [str(helper / 'MergeDiff/merge-diff'), str(helper / 'Git'), str(helper / 'IssueRegex/issue-regex')] if args.three_pane else [str(helper / 'IssueRegex/issue-regex')]
    if args.screenshots: arguments.append(str(args.screenshots.resolve()))
    subprocess.run([str(executable), *arguments],
                   cwd=root, env=environment, check=True, timeout=60)
