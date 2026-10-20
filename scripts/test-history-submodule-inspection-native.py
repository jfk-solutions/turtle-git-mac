#!/usr/bin/env python3
"""Grouped native history warning/Combine and child submodule inspections."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--helper', type=Path)
parser.add_argument('--only', choices=['history','submodule','ownership'], action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
helper = (args.helper or root/'build/libgit2-runtime/LibGit2/bin/turtlegit-libgit2').absolute()
sources = root/'build/qa/history-submodule-inspection-sources'
sources.mkdir(parents=True, exist_ok=True)
fixture = sources/'history-submodule-inspection-native-2026-10-20.swift'
contents = (root/'docs/qa'/fixture.name).read_text()
if not fixture.exists() or fixture.read_text() != contents:
    fixture.write_text(contents)
main = sources/'HistorySubmoduleInspectionMain.swift'
contents = r'''import AppKit
import ObjectiveC
private extension NSWindow {
 @objc func turtleGitHistorySubmoduleOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;setFrameOrigin(.init(x:-12000,y:-12000))
  turtleGitHistorySubmoduleOrder(place,relativeTo:number)
 }
}
@main struct HistorySubmoduleInspectionMain {
 @MainActor static func drain()async throws {
  for _ in 0..<3000 {
   if HistorySubmoduleInspectionVerification.drained() && NSApp.windows.allSatisfy({!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}){return}
   try await Task.sleep(nanoseconds:10_000_000)
  }
  throw HistorySubmoduleInspectionVerification.Failure(description:"Owned history-submodule-inspection work/windows survived cleanup")
 }
 @MainActor static func main()async throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let suite="TurtleGit.HistorySubmodule.Geometry."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
  DialogGeometry.install(preferences:prefs)
  defer{DialogGeometry.install(preferences:.standard);prefs.removePersistentDomain(forName:suite)}
  let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
  let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitHistorySubmoduleOrder(_:relativeTo:)))!
  method_exchangeImplementations(original,hidden);defer{method_exchangeImplementations(original,hidden)}
  do {
   try await HistorySubmoduleInspectionVerification.verify(caseName:ProcessInfo.processInfo.environment["TURTLEGIT_HISTORY_SUBMODULE_CASE"]!,root:URL(fileURLWithPath:CommandLine.arguments[1]),git:URL(fileURLWithPath:CommandLine.arguments[2]),helper:URL(fileURLWithPath:CommandLine.arguments[3]))
  }catch{
   let failure=error
   NSApp.windows.forEach{window in if let parent=window.sheetParent{parent.endSheet(window,returnCode:.abort)};window.close()}
   do{try await drain()}catch{throw HistorySubmoduleInspectionVerification.Failure(description:"\(failure); cleanup: \(error)")}
   throw failure
  }
  NSApp.windows.forEach{$0.close()};try await drain()
  print("PASS: native history-submodule-inspection details case completed")
 }
}
'''
if not main.exists() or main.read_text() != contents:
    main.write_text(contents)
receiver = build_receiver(root, [fixture, main], sources)
with tempfile.TemporaryDirectory(prefix='turtlegit-history-submodule-inspection-') as temporary:
    folder = Path(temporary)
    base = {key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
    base.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for case in args.only or ['history','submodule','ownership']:
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            directory = folder/(case+str(index));directory.mkdir()
            config = directory/'global.config';config.write_text('')
            private_home = directory/'home';private_home.mkdir(mode=0o700)
            private_tmp = directory/'tmp';private_tmp.mkdir(mode=0o700)
            environment = dict(base, GIT_CONFIG_GLOBAL=str(config), XDG_CONFIG_HOME=str(directory/'xdg'), CFFIXED_USER_HOME=str(private_home), TMPDIR=str(private_tmp), TURTLEGIT_HISTORY_SUBMODULE_CASE=case)
            print('Checking history-submodule-inspection details '+case+' with '+str(git), flush=True)
            result = run_receiver([str(receiver), str(directory), str(git.absolute()), str(helper)], cwd=root, env=environment, capture_output=True, text=True, timeout_sample=directory/'timeout.sample.txt')
            print(result.stdout, end='');print(result.stderr, end='');result.check_returncode()
            if 'PASS: native history-submodule-inspection details case completed' not in result.stdout:
                raise SystemExit('History/submodule receiver exited before completion')
