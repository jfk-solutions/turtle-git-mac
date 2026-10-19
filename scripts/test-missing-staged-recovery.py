#!/usr/bin/env python3
"""Grouped Commit/Working Tree missing staged-file recovery and owned prompt lifecycle."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['commit', 'status', 'choices', 'ownership'], action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
sources = root/'build/qa/missing-staged-recovery-sources'
sources.mkdir(parents=True, exist_ok=True)
fixture = sources/'missing-staged-recovery-native-2026-10-20.swift'
text = (root/'docs/qa'/fixture.name).read_text()
if not fixture.is_file() or fixture.read_text() != text:
    fixture.write_text(text)
main = sources/'MissingStagedRecoveryMain.swift'
text = r'''import AppKit
import ObjectiveC
private extension NSWindow {
 @objc func turtleGitMissingStagedOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;setFrameOrigin(.init(x:-12000,y:-12000))
  turtleGitMissingStagedOrder(place,relativeTo:number)
 }
}
@main struct MissingStagedRecoveryMain {
 @MainActor static func main()async throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
  let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitMissingStagedOrder(_:relativeTo:)))!
  method_exchangeImplementations(original,hidden)
  defer{method_exchangeImplementations(original,hidden)}
  let directory=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
  do {
   try await MissingStagedRecoveryVerification.verify(caseName:ProcessInfo.processInfo.environment["TURTLEGIT_MISSING_STAGED_CASE"]!,root:directory,git:git)
  } catch {
   let originalError=error
   for window in NSApp.windows {if let parent=window.sheetParent {parent.endSheet(window,returnCode:.abort)};window.close()}
   do {try await MissingStagedRecoveryVerification.drain()} catch {throw MissingStagedRecoveryVerification.Failure(description:"\(originalError); owned cleanup failed: \(error)")}
   throw originalError
  }
  print("PASS: Missing staged-file recovery native case completed")
 }
}
'''
if not main.is_file() or main.read_text() != text:
    main.write_text(text)
receiver = build_receiver(root, [fixture, main], sources)
with tempfile.TemporaryDirectory(prefix='turtlegit-missing-staged-') as temporary:
    folder = Path(temporary)
    base = {key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
    base.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for case in args.only or ['commit', 'status', 'choices', 'ownership']:
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            directory = folder/(case+str(index));directory.mkdir()
            configuration = directory/'global.config';configuration.write_text('')
            private_tmp = directory/'temporary';private_tmp.mkdir(mode=0o700)
            private_home = directory/'home';private_home.mkdir(mode=0o700)
            env = dict(base, GIT_CONFIG_GLOBAL=str(configuration), XDG_CONFIG_HOME=str(directory/'xdg'), TMPDIR=str(private_tmp),
                       CFFIXED_USER_HOME=str(private_home), TURTLEGIT_MISSING_STAGED_CASE=case)
            print('Checking missing staged-file '+case+' with '+str(git), flush=True)
            result = run_receiver([str(receiver), str(directory/'repository'), str(git.absolute())], cwd=root, env=env,
                                  capture_output=True, text=True, timeout_sample=directory/'timeout.sample.txt')
            print(result.stdout, end='');print(result.stderr, end='');result.check_returncode()
            if 'PASS: Missing staged-file recovery native case completed' not in result.stdout:
                raise SystemExit('Missing staged-file receiver exited before completion: '+case)
