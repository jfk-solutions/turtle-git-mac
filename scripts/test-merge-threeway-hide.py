#!/usr/bin/env python3
"""Grouped three-way HideState ownership and retained two-pane classifications.

Uses the current Debug app objects and native_receiver's architecture/framework/
compiler/source cache. Every receiver owns private repositories, preferences and
TMPDIR; its windows are transparent/offscreen and its process group is reaped.
"""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['options', 'ignored', 'two-pane'], action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
engines = args.git or [Path('/usr/bin/git'), root / 'build/git-runtime/Git/bin/git']
for engine in engines:
    if not engine.is_file():
        raise SystemExit('Prepare the requested Git runtime before grouped native QA: ' + str(engine))
with tempfile.TemporaryDirectory(prefix='tg-threeway-hide-') as temporary:
    folder = Path(temporary)
    sources = []
    inputs = root / 'build/qa/merge-threeway-hide-sources'
    inputs.mkdir(parents=True, exist_ok=True)
    def write_changed(path, text):
        if not path.is_file() or path.read_text() != text:
            path.write_text(text)
    for name in ['merge-threeway-hide-native-2026-10-19.swift',
                 'merge-whitespace-states-native-2026-10-15.swift',
                 'two-pane-engine-native-2026-10-12.swift']:
        source = inputs / name
        write_changed(source, (root / 'docs/qa' / name).read_text().replace('@main ', '', 1))
        sources.append(source)
    main = inputs / 'HideStateMain.swift'
    write_changed(main, '''import AppKit
import ObjectiveC
private extension NSWindow {
    @objc func turtleGitHideStateOrder(_ place: NSWindow.OrderingMode, relativeTo number: Int) {
        alphaValue = 0
        if place != .out { setFrameOrigin(NSPoint(x: -20000, y: -20000)) }
        turtleGitHideStateOrder(place, relativeTo: number)
    }
}
@main struct HideStateMain {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let original = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.order(_:relativeTo:)))!
        let hidden = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.turtleGitHideStateOrder(_:relativeTo:)))!
        method_exchangeImplementations(original, hidden)
        defer { method_exchangeImplementations(original, hidden) }
        if CommandLine.arguments[3] == "two-pane" {
            try await MergeWhitespaceStatesVerification.verify()
        } else {
            try await MergeThreewayHideVerification.main()
        }
        try await MergeThreewayHideVerification.wait {
            MergeRegexOperations.activeRequests == 0 && MergeSourceExport.activeExports == 0 &&
            MergeExternalReloadCoordinator.activeRequests == 0 &&
            NSApp.windows.allSatisfy { !$0.isVisible && $0.attachedSheet == nil }
        }
        print("PASS: grouped HideState native case completed")
    }
}
''')
    receiver = build_receiver(root, sources + [main], folder)
    baseline = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    baseline.update(DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'),
                    GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for key in ['TURTLEGIT_WRAP_CAPTURE', 'TURTLEGIT_MERGE_IGNORED_CASE']:
        baseline.pop(key, None)
    for index, engine in enumerate(engines):
        for case in args.only or ['options', 'ignored', 'two-pane']:
            directory = folder / (str(index) + '-' + case)
            directory.mkdir()
            temporary_files = directory / 'tmp'
            temporary_files.mkdir()
            env = dict(baseline, TMPDIR=str(temporary_files) + '/')
            print('Checking HideState ' + case + ' with ' + str(engine), flush=True)
            result = run_receiver([str(receiver), str(directory), str(engine.absolute()), case],
                                  cwd=root, env=env, capture_output=True, text=True,
                                  timeout=240, timeout_sample=root / 'build/qa/merge-threeway-hide-timeout.txt')
            print(result.stdout, end=''); print(result.stderr, end='')
            result.check_returncode()
            if 'PASS: grouped HideState native case completed' not in result.stdout:
                raise SystemExit('Receiver exited before final assertions: ' + case)
