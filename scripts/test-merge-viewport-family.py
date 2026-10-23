#!/usr/bin/env python3
"""Grouped private Compare/Merge one-cell viewport commands and owner fencing."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
generated = root / 'build/qa/merge-viewport-native-sources'
generated.mkdir(parents=True, exist_ok=True)
main = generated / 'MergeViewportMain.swift'
source = '''import AppKit
import ObjectiveC
private extension NSWindow {
 @objc func turtleViewportHiddenOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;setFrameOrigin(.init(x:-12000,y:-12000));turtleViewportHiddenOrder(place,relativeTo:number)
 }
}
@main enum MergeViewportMain {
 @MainActor static func main()async throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
  let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleViewportHiddenOrder(_:relativeTo:)))!
  method_exchangeImplementations(original,hidden)
  defer{method_exchangeImplementations(original,hidden);DialogGeometry.install(preferences:.standard)}
  do {try await MergeViewportVerification.verify()}
  catch {
   let failure=error
   for window in NSApp.windows {if let parent=window.sheetParent {parent.endSheet(window,returnCode:.cancel)};window.close()}
   do{try await MergePaneInputVerification.drain()}catch{throw MergePaneInputVerification.Failure(description:"\\(failure); viewport cleanup: \\(error)")}
   throw failure
  }
  print("PASS: Compare/Merge viewport family completed")
 }
}
'''
if not main.is_file() or main.read_text() != source:
    main.write_text(source)
receiver = build_receiver(root, [root / 'docs/qa/merge-pane-input-native-2026-10-19.swift',
                                 root / 'docs/qa/merge-viewport-native-2026-10-23.swift', main], generated)
for git in args.git or [Path('/usr/bin/git'), root / 'build/git-runtime/Git/bin/git']:
    with tempfile.TemporaryDirectory(prefix='turtlegit-merge-viewport-') as temporary:
        context = Path(temporary)
        fixture, preferences, scratch, xdg = [context / name for name in ('fixture', 'preferences', 'temporary', 'xdg')]
        for directory in (fixture, preferences, scratch, xdg):
            directory.mkdir(mode=0o700)
        config = context / 'global.config'
        config.write_text('')
        environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
        environment.update(GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                           CFFIXED_USER_HOME=str(preferences), XDG_CONFIG_HOME=str(xdg), TMPDIR=str(scratch) + '/',
                           DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'))
        print('Checking Compare/Merge viewport commands with ' + str(git), flush=True)
        result = run_receiver([str(receiver), str(fixture), str(git.absolute())], cwd=root,
                              env=environment, capture_output=True, text=True,
                              timeout_sample=context / 'timeout.sample.txt')
        print(result.stdout, end='')
        print(result.stderr, end='')
        result.check_returncode()
        if 'PASS: Compare/Merge viewport family completed' not in result.stdout:
            raise SystemExit('Viewport receiver exited before completion')
