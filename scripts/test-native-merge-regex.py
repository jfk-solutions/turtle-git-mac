#!/usr/bin/env python3
"""One compilation and one focused native regex receiver; no installed app."""
from pathlib import Path
import os
import hashlib
import argparse
import platform
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--three-pane', action='store_true')
parser.add_argument('--two-pane', action='store_true')
parser.add_argument('--options-batch', action='store_true')
parser.add_argument('--whitespace-only', action='store_true')
parser.add_argument('--general-only', action='store_true')
parser.add_argument('--about-only', action='store_true')
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
    if args.options_batch or args.whitespace_only or args.general_only or args.about_only:
        for name in ['three-pane-engine-native-2026-10-12.swift', 'two-pane-engine-native-2026-10-12.swift', 'merge-locator-native-2026-10-12.swift', 'merge-whitespace-display-native-2026-10-12.swift', 'merge-general-native-2026-10-12.swift', 'about-native-2026-10-12.swift']:
            receiver = folder / name
            receiver.write_text((root / 'docs/qa' / name).read_text().replace('@main struct', 'struct', 1))
            additional.append(str(receiver))
    primary = root / ('docs/qa/comparison-options-native-2026-10-12.swift' if args.options_batch or args.whitespace_only or args.general_only or args.about_only else 'docs/qa/two-pane-engine-native-2026-10-12.swift' if args.two_pane else 'docs/qa/three-pane-engine-native-2026-10-12.swift' if args.three_pane else 'docs/qa/merge-regex-native-2026-10-12.swift')
    # Focused modes and the full options batch share the same executable. Rebuild
    # only after source, imported framework, architecture or compiler changes.
    digest = hashlib.sha256()
    digest.update((platform.machine() + '-apple-macos13.0/swift5/WMO-Onone/merge-receiver-v1').encode())
    digest.update(subprocess.check_output(['xcrun', 'swiftc', '--version']))
    framework = products / 'TurtleGitCore.framework'
    inputs = [*map(Path, sources), copy, *map(Path, additional), primary]
    inputs += sorted(p for p in framework.rglob('*') if p.is_file() and not p.is_symlink())
    for source in inputs:
        digest.update(source.name.encode()); digest.update(source.read_bytes())
    cache = root / 'build/qa/native-receivers'; cache.mkdir(parents=True, exist_ok=True)
    executable = cache / ('merge-' + digest.hexdigest())
    if not executable.exists():
        staging = folder / 'merge-regex-native-receiver'
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-whole-module-optimization', '-Onone',
                        '-target', platform.machine() + '-apple-macos13.0', '-I', str(products), '-F', str(products),
                        *sources, str(copy), *additional, str(primary),
                        '-framework', 'TurtleGitCore', '-o', str(staging)], cwd=root, check=True)
        staging.replace(executable)
        print('Native Merge receiver compiled once for this source/framework/toolchain.', flush=True)
    else:
        print('Reusing native Merge receiver for unchanged source/framework/toolchain.', flush=True)
    environment = os.environ.copy(); environment['DYLD_FRAMEWORK_PATH'] = str(products)
    helper = products / 'TurtleGitMac.app/Contents/Helpers'
    arguments = [str(helper / 'MergeDiff/merge-diff'), str(helper / 'Git'), str(helper / 'IssueRegex/issue-regex')] if args.three_pane else [str(helper / 'IssueRegex/issue-regex')]
    if args.whitespace_only: arguments.append('--whitespace-only')
    if args.general_only: arguments.append('--general-only')
    if args.about_only: arguments.append('--about-only')
    if args.screenshots: arguments.append(str(args.screenshots.resolve()))
    subprocess.run([str(executable), *arguments],
                   cwd=root, env=environment, check=True, timeout=60)
