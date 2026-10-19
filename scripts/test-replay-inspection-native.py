#!/usr/bin/env python3
"""Grouped native replay/readiness/conflict inspection and Resolve stage engine ownership."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--helper', type=Path)
parser.add_argument('--editor', type=Path)
parser.add_argument('--only', choices=['replay','resolve','completion','fetch','svn','ownership'], action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
helper = (args.helper or root/'build/libgit2-runtime/LibGit2/bin/turtlegit-libgit2').absolute()
editor = (args.editor or root/'build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac').absolute()
sources = root/'build/qa/replay-inspection-sources'
sources.mkdir(parents=True, exist_ok=True)
fixture = sources/'replay-inspection-native-2026-10-20.swift'
contents = (root/'docs/qa'/fixture.name).read_text()
if not fixture.exists() or fixture.read_text() != contents:
    fixture.write_text(contents)
main = sources/'ReplayInspectionMain.swift'
contents = r'''import AppKit
import ObjectiveC
private extension NSWindow {
 @objc func turtleGitReplayInspectionOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;setFrameOrigin(.init(x:-12000,y:-12000))
  turtleGitReplayInspectionOrder(place,relativeTo:number)
 }
}
@main struct ReplayInspectionMain {
 @MainActor static func drain()async throws {
  for _ in 0..<3000 {
   if ReplayInspectionVerification.drained() && NSApp.windows.allSatisfy({!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}){return}
   try await Task.sleep(nanoseconds:10_000_000)
  }
  throw ReplayInspectionVerification.Failure(description:"Owned replay inspection work/windows survived cleanup")
 }
 @MainActor static func main()async throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let suite="TurtleGit.ReplayInspection.Geometry."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
  DialogGeometry.install(preferences:prefs)
  defer{DialogGeometry.install(preferences:.standard);prefs.removePersistentDomain(forName:suite)}
  let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
  let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitReplayInspectionOrder(_:relativeTo:)))!
  method_exchangeImplementations(original,hidden);defer{method_exchangeImplementations(original,hidden)}
  do {
   try await ReplayInspectionVerification.verify(caseName:ProcessInfo.processInfo.environment["TURTLEGIT_INSPECTION_CASE"]!,root:URL(fileURLWithPath:CommandLine.arguments[1]),git:URL(fileURLWithPath:CommandLine.arguments[2]),helper:URL(fileURLWithPath:CommandLine.arguments[3]),editor:URL(fileURLWithPath:CommandLine.arguments[4]))
  }catch{
   let failure=error
   NSApp.windows.forEach{window in if let parent=window.sheetParent{parent.endSheet(window,returnCode:.abort)};window.close()}
   do{try await drain()}catch{throw ReplayInspectionVerification.Failure(description:"\(failure); cleanup: \(error)")}
   throw failure
  }
  NSApp.windows.forEach{$0.close()};try await drain()
  print("PASS: native replay inspection case completed")
 }
}
'''
if not main.exists() or main.read_text() != contents:
    main.write_text(contents)
receiver = build_receiver(root, [fixture, main], sources)
with tempfile.TemporaryDirectory(prefix='turtlegit-replay-inspection-') as temporary:
    folder = Path(temporary)
    base = {key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
    base.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for case in args.only or ['replay','resolve','completion','fetch','svn','ownership']:
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            directory = folder/(case+str(index));directory.mkdir()
            config = directory/'global.config';config.write_text('')
            private_home = directory/'home';private_home.mkdir(mode=0o700)
            private_tmp = directory/'tmp';private_tmp.mkdir(mode=0o700)
            environment = dict(base, GIT_CONFIG_GLOBAL=str(config), XDG_CONFIG_HOME=str(directory/'xdg'), CFFIXED_USER_HOME=str(private_home), TMPDIR=str(private_tmp), TURTLEGIT_INSPECTION_CASE=case)
            print('Checking replay inspection '+case+' with '+str(git), flush=True)
            result = run_receiver([str(receiver), str(directory), str(git.absolute()), str(helper), str(editor)], cwd=root, env=environment, capture_output=True, text=True, timeout_sample=directory/'timeout.sample.txt')
            print(result.stdout, end='');print(result.stderr, end='');result.check_returncode()
            if 'PASS: native replay inspection case completed' not in result.stdout:
                raise SystemExit('Replay inspection receiver exited before completion')
