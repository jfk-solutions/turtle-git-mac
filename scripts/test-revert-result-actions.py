#!/usr/bin/env python3
"""Grouped Revert completed-file actions and retained operation/retry lifecycle."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['result-actions', 'retained-operation', 'retained-add-resolve'], action='append')
parser.add_argument('--captures', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
sources = root/'build/qa/revert-result-actions-sources'
sources.mkdir(parents=True, exist_ok=True)
fixtures = []
for filename in ['revert-result-actions-native-2026-10-19.swift', 'revert-progress-family-native-2026-10-14.swift', 'add-resolve-progress-native-2026-10-19.swift']:
    target = sources/filename
    text = (root/'docs/qa'/filename).read_text().replace('@main ', '', 1)
    if not target.is_file() or target.read_text() != text:
        target.write_text(text)
    fixtures.append(target)
main = sources/'RevertResultActionsMain.swift'
text = r'''import AppKit
import ObjectiveC
private extension NSWindow {
 @objc func turtleGitRevertResultOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;setFrameOrigin(.init(x:-12000,y:-12000))
  turtleGitRevertResultOrder(place,relativeTo:number)
 }
}
@main struct RevertResultActionsMain {
 @MainActor static func main()async throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
  let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitRevertResultOrder(_:relativeTo:)))!
  method_exchangeImplementations(original,hidden)
  defer{method_exchangeImplementations(original,hidden)}
  do {
  switch ProcessInfo.processInfo.environment["TURTLEGIT_REVERT_RESULT_CASE"]! {
  case "result-actions":try await RevertResultActionsVerification.verify()
  case "retained-operation":try await RevertProgressFamilyVerification.verify();try await RevertResultActionsVerification.drain()
  case "retained-add-resolve":try await AddResolveProgressVerification.verify();try await RevertResultActionsVerification.drain()
  default:fatalError("Unknown Revert result case")
  }
  } catch {
   for window in NSApp.windows {if let parent=window.sheetParent {parent.endSheet(window,returnCode:.cancel)};window.close()}
   let failure=error
   do {try await RevertResultActionsVerification.drain()} catch {throw RevertResultActionsVerification.Failure(description:"\(failure); grouped cleanup failed: \(error)")}
   throw failure
  }
  print("PASS: Revert result actions native case completed")
 }
}
'''
if not main.is_file() or main.read_text() != text:
    main.write_text(text)
receiver = build_receiver(root, fixtures+[main], sources)
with tempfile.TemporaryDirectory(prefix='turtlegit-revert-results-') as temporary:
    folder = Path(temporary)
    base = {key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
    base.pop('TURTLEGIT_PROGRESS_CAPTURES', None)
    base.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for case in args.only or ['result-actions', 'retained-operation', 'retained-add-resolve']:
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            directory = folder/(case+str(index));directory.mkdir()
            config = directory/'global.config';config.write_text('')
            private_tmp = directory/'temporary';private_tmp.mkdir(mode=0o700)
            env = dict(base, GIT_CONFIG_GLOBAL=str(config), XDG_CONFIG_HOME=str(directory/'xdg'), TMPDIR=str(private_tmp), TURTLEGIT_REVERT_RESULT_CASE=case)
            if args.captures and case == 'result-actions' and index == 0:
                env['TURTLEGIT_REVERT_RESULT_CAPTURES'] = str(args.captures.absolute())
            else:
                env.pop('TURTLEGIT_REVERT_RESULT_CAPTURES', None)
            print('Checking Revert '+case+' with '+str(git), flush=True)
            result = run_receiver([str(receiver), str(directory), str(git.absolute())], cwd=root, env=env,
                                  capture_output=True, text=True, timeout_sample=directory/'timeout.sample.txt')
            print(result.stdout, end='');print(result.stderr, end='');result.check_returncode()
            if 'PASS: Revert result actions native case completed' not in result.stdout:
                raise SystemExit('Revert result receiver exited before completion: '+case)
