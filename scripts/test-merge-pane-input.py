#!/usr/bin/env python3
"""Grouped native folded pane input, ghost deletion and retained typing/history."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
cases = ['navigation', 'editing', 'ownership', 'typing', 'history', 'words', 'word-editing', 'word-ownership']
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=cases, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
inputs = root/'build/qa/merge-pane-input-sources'
inputs.mkdir(parents=True, exist_ok=True)
sources = []
for name in ['merge-pane-input-native-2026-10-19.swift', 'merge-word-input-native-2026-10-20.swift', 'merge-typing-native-2026-10-16.swift',
             'merge-edit-history-native-2026-10-18.swift', 'merge-menu-lifecycle-native-2026-10-16.swift',
             'two-pane-engine-native-2026-10-12.swift', 'three-pane-engine-native-2026-10-12.swift']:
    target = inputs/name
    text = (root/'docs/qa'/name).read_text().replace('@main ', '', 1)
    if not target.is_file() or target.read_text() != text:
        target.write_text(text)
    sources.append(target)
main = inputs/'MergePaneInputMain.swift'
text = r'''import AppKit
import ObjectiveC
private extension NSWindow {
 @objc func turtleGitPaneInputOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;setFrameOrigin(.init(x:-12000,y:-12000))
  turtleGitPaneInputOrder(place,relativeTo:number)
 }
}
@main struct MergePaneInputMain {
 @MainActor static func main()async throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
  let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitPaneInputOrder(_:relativeTo:)))!
  method_exchangeImplementations(original,hidden)
  defer{method_exchangeImplementations(original,hidden)}
  let test=ProcessInfo.processInfo.environment["TURTLEGIT_PANE_INPUT_CASE"]!
  do {
   switch test {
   case "typing":try await MergeTypingVerification.verify()
   case "history":try await MergeEditHistoryVerification.verify()
   case "words","word-editing","word-ownership":try await MergeWordInputVerification.verify(test)
   default:try await MergePaneInputVerification.verify(test)
   }
   try await MergePaneInputVerification.drain()
  } catch {
   let failure=error
   for window in NSApp.windows {if let parent=window.sheetParent {parent.endSheet(window,returnCode:.cancel)};window.close()}
   do{try await MergePaneInputVerification.drain()}catch{throw MergePaneInputVerification.Failure(description:"\(failure); grouped cleanup: \(error)")}
   throw failure
  }
  print("PASS: pane input native case completed")
 }
}
'''
if not main.is_file() or main.read_text() != text:
    main.write_text(text)
receiver = build_receiver(root, sources+[main], inputs)
with tempfile.TemporaryDirectory(prefix='turtlegit-pane-input-') as temporary:
    base = {key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
    for key in ['TURTLEGIT_WRAP_CAPTURE', 'TURTLEGIT_MENU_CAPTURE', 'TURTLEGIT_VIEW_CAPTURE']:
        base.pop(key, None)
    base.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for case in args.only or cases:
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            directory = Path(temporary)/(case+str(index));directory.mkdir()
            config = directory/'global.config';config.write_text('')
            private_tmp = directory/'temporary';private_tmp.mkdir(mode=0o700)
            env = dict(base, GIT_CONFIG_GLOBAL=str(config), XDG_CONFIG_HOME=str(directory/'xdg'), TMPDIR=str(private_tmp), TURTLEGIT_PANE_INPUT_CASE=case)
            print('Checking pane input '+case+' with '+str(git), flush=True)
            result = run_receiver([str(receiver), str(directory), str(git.absolute())], cwd=root, env=env,
                                  capture_output=True, text=True, timeout_sample=directory/'timeout.sample.txt')
            print(result.stdout, end='');print(result.stderr, end='');result.check_returncode()
            if 'PASS: pane input native case completed' not in result.stdout:
                raise SystemExit('Pane input receiver exited before completion: '+case)
