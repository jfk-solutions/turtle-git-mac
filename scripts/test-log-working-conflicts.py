#!/usr/bin/env python3
"""Run the full retained replay fixture's native Log working-conflict family.

Uses the cached Debug native receiver, private process homes and invisible owned
windows. This is model/controller acceptance, not physical gesture acceptance.
"""
import argparse
import os
import tempfile
from pathlib import Path
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-log-working-conflicts-') as temporary:
    directory = Path(temporary)
    original = root / 'docs/qa/cherry-pick-native-receiver-2026-10-06.swift'
    source = original.read_text()
    assert source.count('@main struct Receiver') == 1, 'Original replay entry point changed'
    copied = directory / 'RetainedLogWorkingConflicts.swift'
    copied.write_text(source.replace('@main struct Receiver', 'struct Receiver', 1))
    main = directory / 'LogWorkingConflictsMain.swift'
    main.write_text('''import AppKit
import ObjectiveC
private extension NSWindow {
 @objc func logWorkingConflictOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;setFrameOrigin(.init(x:-18000,y:-18000));logWorkingConflictOrder(mode,relativeTo:number)
 }
}
@main struct LogWorkingConflictsMain {
 @MainActor static func main() async throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
  let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.logWorkingConflictOrder(_:relativeTo:)))!
  method_exchangeImplementations(original,hidden)
  defer {for window in NSApp.windows {window.close()};method_exchangeImplementations(original,hidden)}
  try await verifyNativeLogWorkingConflicts(executable:URL(fileURLWithPath:CommandLine.arguments[2]))
  print("PASS: full retained native Log working-conflict family")
 }
}
''')
    receiver = build_receiver(root, [copied, main], directory)
    base = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    base.update(DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'),
                GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
        case = directory / str(index)
        case.mkdir(mode=0o700)
        home = case / 'home'
        (home / 'Library/Preferences').mkdir(parents=True, mode=0o700)
        tmp = case / 'temporary'
        tmp.mkdir(mode=0o700)
        xdg = case / 'xdg'
        xdg.mkdir(mode=0o700)
        env = dict(base, HOME=str(home), CFFIXED_USER_HOME=str(home),
                   TMPDIR=str(tmp) + '/', XDG_CONFIG_HOME=str(xdg))
        print('Checking full Log working-conflict family with ' + str(git), flush=True)
        result = run_receiver([str(receiver), str(case), str(git.absolute())], cwd=root,
                              env=env, capture_output=True, text=True)
        print(result.stdout, end='')
        print(result.stderr, end='')
        result.check_returncode()
        if result.stdout.count('PASS: full retained native Log working-conflict family') != 1:
            raise SystemExit('Log working-conflict receiver did not complete exactly once')
