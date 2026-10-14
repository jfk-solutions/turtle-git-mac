#!/usr/bin/env python3
"""One compilation and one focused native regex receiver; no installed app."""
from pathlib import Path
import os
import ast
import re
import signal
import time
import hashlib
import argparse
import platform
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--three-pane', action='store_true')
parser.add_argument('--two-pane', action='store_true')
parser.add_argument('--options-batch', action='store_true')
parser.add_argument('--resume-from-line-diff', action='store_true', help='Resume an options batch after its unchanged passing encoding family.')
parser.add_argument('--resume-after-engines', action='store_true', help='Resume a failed options batch after its two unchanged passing engine families.')
parser.add_argument('--whitespace-only', action='store_true')
parser.add_argument('--general-only', action='store_true')
parser.add_argument('--about-only', action='store_true')
parser.add_argument('--find-only', action='store_true')
parser.add_argument('--open-only', action='store_true')
parser.add_argument('--format-only', action='store_true')
parser.add_argument('--patch-only', action='store_true')
parser.add_argument('--colors-only', action='store_true')
parser.add_argument('--one-pane-only', action='store_true')
parser.add_argument('--one-pane-context-only', action='store_true')
parser.add_argument('--default-encoding-only', action='store_true')
parser.add_argument('--wrapping-only', action='store_true')
parser.add_argument('--inline-only', action='store_true')
parser.add_argument('--folding-only', action='store_true')
parser.add_argument('--editor-open-only', action='store_true')
parser.add_argument('--patch-open-only', action='store_true')
parser.add_argument('--screenshots', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='turtlegit-merge-regex-native-') as temporary:
    folder = Path(temporary)
    objects = sorted((root / 'build/Build/Intermediates.noindex/TurtleGitMac.build/Debug/TurtleGitMac.build/Objects-normal' / platform.machine()).glob('*.o'))
    if not objects or not (products / 'TurtleGitMac.swiftmodule').exists():
        raise SystemExit('Build TurtleGitMac Debug before running Merge QA.')
    additional = []
    if args.options_batch or args.whitespace_only or args.general_only or args.about_only or args.find_only or args.open_only or args.format_only or args.patch_only or args.colors_only or args.one_pane_only or args.one_pane_context_only or args.default_encoding_only or args.wrapping_only or args.inline_only or args.folding_only or args.editor_open_only or args.patch_open_only:
        for name in ['three-pane-engine-native-2026-10-12.swift', 'two-pane-engine-native-2026-10-12.swift', 'merge-locator-native-2026-10-12.swift', 'merge-whitespace-display-native-2026-10-12.swift', 'merge-general-native-2026-10-12.swift', 'about-native-2026-10-12.swift', 'merge-find-native-2026-10-12.swift', 'merge-open-native-2026-10-12.swift', 'merge-format-native-2026-10-12.swift', 'merge-line-diff-native-2026-10-12.swift', 'merge-patch-native-2026-10-12.swift', 'merge-colors-native-2026-10-12.swift', 'merge-one-pane-native-2026-10-12.swift', 'merge-one-pane-context-native-2026-10-12.swift', 'merge-default-encoding-native-2026-10-12.swift', 'merge-wrapping-native-2026-10-12.swift', 'merge-inline-native-2026-10-14.swift', 'merge-folding-native-2026-10-14.swift', 'merge-editor-open-native-2026-10-14.swift', 'merge-patch-open-native-2026-10-14.swift', 'review-patch-native-2026-10-12.swift']:
            receiver = folder / name
            receiver.write_text('@testable import TurtleGitMac\n' + (root / 'docs/qa' / name).read_text().replace('@main struct', 'struct', 1))
            additional.append(str(receiver))
    primary = root / ('docs/qa/comparison-options-native-2026-10-12.swift' if args.options_batch or args.whitespace_only or args.general_only or args.about_only or args.find_only or args.open_only or args.format_only or args.patch_only or args.colors_only or args.one_pane_only or args.one_pane_context_only or args.default_encoding_only or args.wrapping_only or args.inline_only or args.folding_only or args.editor_open_only or args.patch_open_only else 'docs/qa/two-pane-engine-native-2026-10-12.swift' if args.two_pane else 'docs/qa/three-pane-engine-native-2026-10-12.swift' if args.three_pane else 'docs/qa/merge-regex-native-2026-10-12.swift')
    primary_text = primary.read_text()
    primary_name = re.search(r'@main struct (\w+)', primary_text).group(1)
    primary_copy = folder / 'Primary.swift'
    primary_copy.write_text('@testable import TurtleGitMac\n' + primary_text.replace('@main struct', 'struct', 1))
    bootstrap = folder / 'Bootstrap.swift'
    bootstrap.write_text('import AppKit\n@_cdecl("turtlegit_merge_receiver_main") func bootstrap() -> Int32 {\n    NSApplication.shared.setActivationPolicy(.prohibited)\n    Task { @MainActor in\n        do { try await ' + primary_name + '.main(); exit(0) }\n        catch { fputs("FAIL: \\(error)\\n", stderr); exit(1) }\n    }\n    NSApplication.shared.run(); return 0\n}\n')
    # Modes share a cache keyed by built objects, both modules, QA and toolchain.
    digest = hashlib.sha256()
    digest.update((platform.machine() + '-apple-macos13.0/swift5/WMO-Onone/merge-objects-v2').encode())
    digest.update(subprocess.check_output(['xcrun', 'swiftc', '--version']))
    framework = products / 'TurtleGitCore.framework'
    inputs = [*objects, *map(Path, additional), primary_copy, bootstrap]
    for imported in [framework, products / 'TurtleGitMac.swiftmodule']:
        inputs += sorted(p for p in imported.rglob('*') if p.is_file() and not p.is_symlink())
    for source in inputs:
        digest.update(source.name.encode()); digest.update(source.read_bytes())
    cache = root / 'build/qa/native-receivers'; cache.mkdir(parents=True, exist_ok=True)
    executable = cache / ('merge-' + digest.hexdigest())
    if not executable.exists():
        staging = folder / 'merge-regex-native-receiver'
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-whole-module-optimization', '-Onone',
                        '-target', platform.machine() + '-apple-macos13.0', '-I', str(products), '-F', str(products),
                        *additional, str(primary_copy), str(bootstrap), *map(str, objects),
                        '-framework', 'TurtleGitCore', '-Xlinker', '-rpath', '-Xlinker', str(products),
                        '-Xlinker', '-e', '-Xlinker', '_turtlegit_merge_receiver_main',
                        '-o', str(staging)], cwd=root, check=True, timeout=300)
        staging.replace(executable)
        print('Native Merge receiver linked once to current Debug app objects.', flush=True)
    else:
        print('Reusing native Merge receiver for unchanged source/framework/toolchain.', flush=True)
    environment = os.environ.copy(); environment['DYLD_FRAMEWORK_PATH'] = str(products)
    if args.find_only and args.screenshots:
        environment['TURTLEGIT_MERGE_FIND_CAPTURE'] = str(args.screenshots.resolve())
    helper = products / 'TurtleGitMac.app/Contents/Helpers'
    arguments = [str(helper / 'MergeDiff/merge-diff'), str(helper / 'Git'), str(helper / 'IssueRegex/issue-regex')] if args.three_pane else [str(helper / 'IssueRegex/issue-regex')]
    if args.whitespace_only: arguments.append('--whitespace-only')
    if args.general_only: arguments.append('--general-only')
    if args.about_only: arguments.append('--about-only')
    if args.find_only: arguments.append('--find-only')
    if args.open_only: arguments.append('--open-only')
    if args.format_only: arguments.append('--format-only')
    if args.patch_only: arguments.append('--patch-only')
    if args.colors_only: arguments.append('--colors-only')
    if args.one_pane_only: arguments.append('--one-pane-only')
    if args.one_pane_context_only: arguments.append('--one-pane-context-only')
    if args.default_encoding_only: arguments.append('--default-encoding-only')
    if args.wrapping_only: arguments.append('--wrapping-only')
    if args.inline_only: arguments.append('--inline-only')
    if args.folding_only: arguments.append('--folding-only')
    if args.editor_open_only: arguments.append('--editor-open-only')
    if args.patch_open_only: arguments.append('--patch-open-only')
    if args.resume_after_engines:
        if not args.options_batch: raise SystemExit('--resume-after-engines requires --options-batch')
        arguments.append('--resume-after-engines')
    if args.resume_from_line_diff:
        if not args.options_batch: raise SystemExit('--resume-from-line-diff requires --options-batch')
        arguments.append('--resume-from-line-diff')
    if args.screenshots: arguments.append(str(args.screenshots.resolve()))
    driver = ast.parse((root / 'scripts/test-synchronization-dialog.py').read_text())
    helper_node = next(node for node in driver.body if isinstance(node, ast.FunctionDef) and node.name == 'close_receiver')
    cleanup = {'os': os, 'signal': signal, 'time': time, 'subprocess': subprocess}
    exec(compile(ast.Module(body=[helper_node], type_ignores=[]), '<owned Merge receiver cleanup>', 'exec'), cleanup)
    receiver = subprocess.Popen([str(executable), *arguments], cwd=root, env=environment, start_new_session=True)
    try:
        code = receiver.wait(timeout=60)
        if code: raise subprocess.CalledProcessError(code, receiver.args)
    finally:
        cleanup['close_receiver'](receiver)
        print('Owned Merge receiver reaped: ' + str(receiver.pid), flush=True)
