#!/usr/bin/env python3
"""Grouped current-object Compare/Merge Find checks, with owned process cleanup."""
from pathlib import Path
import tempfile
import argparse
import os
from native_receiver import build_receiver, run_receiver
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='TurtleGitFindHighlights-') as temporary:
    directory = Path(temporary)
    main = directory / 'main.swift'
    main.write_text('import AppKit\n@main struct FindHighlightsVerification { @MainActor static func main() async throws { NSApplication.shared.setActivationPolicy(.prohibited); try await MergeFindNativeVerification.verify(); try await MergeMarkedWordNativeVerification.verify(); print("PASS: connected native Compare/Merge Find, paint, selected-text commands, Undo, menus and ownership"); } }\n')
    binary = build_receiver(root, [main, root / 'docs/qa/merge-find-native-2026-10-12.swift', root / 'docs/qa/merge-marked-word-native-2026-10-15.swift'], directory)
    environment = os.environ.copy()
    environment.update(DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
    for git in args.git or [Path('/usr/bin/git')]:
        environment['TURTLEGIT_FIND_TEST_GIT'] = str(git.absolute())
        print('Checking native Find family with ' + str(git), flush=True)
        run_receiver([str(binary)], cwd=root, env=environment, check=True)
