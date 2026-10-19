#!/usr/bin/env python3
"""Grouped Switch/Reset command receipts, native recovery lifetime and retained Git/post-action behavior."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

CASES = {
    'switch': 'try await SwitchProgressFamilyVerification.verify()',
    'reset': 'try await ResetProgressFamilyVerification.verify()',
    'switch-retained': 'try await SwitchProgressVerification.main()',
    'reset-retained': 'try await ResetProgressVerification.main()',
}
FILES = ['switch-progress-family-native-2026-10-19.swift',
         'reset-progress-family-native-2026-10-19.swift',
         'switch-progress-native-2026-10-08.swift',
         'reset-progress-native-2026-10-08.swift']
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=CASES, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
sources = root/'build/qa/switch-reset-progress-family-sources'
sources.mkdir(parents=True, exist_ok=True)
fixtures = []
for filename in FILES:
    target = sources/filename
    contents = (root/'docs/qa'/filename).read_text().replace('@main ', '', 1)
    if not target.is_file() or target.read_text() != contents:
        target.write_text(contents)
    fixtures.append(target)
main = sources/'SwitchResetProgressFamilyMain.swift'
contents = r'''import AppKit
import ObjectiveC
import TurtleGitCore
private extension NSWindow {
 @objc func turtleGitSwitchResetProgressOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;turtleGitSwitchResetProgressOrder(place,relativeTo:number)
 }
}
@main struct SwitchResetProgressFamilyMain {
 @MainActor static func drain()async throws {
  for _ in 0..<3000 {
   if SwitchProgressWindowModel.activeOperations==0 && ResetProgressWindowModel.activeOperations==0 && SwitchWindowController.activeChildReleases==0 && ResetWindowController.activeChildReleases==0 && SwitchWindowModel.activeReads==0 && ResetWindowModel.activeReads==0 && LocalGitCommandProgress.activeOperations==0 && SubmoduleUpdateWindowModel.activeReads==0 && CommitWindowModel.activeReloads==0 && CommitWindowModel.activeCommitPreflights==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activePreferenceOperations==0 && CommitWindowModel.activeIssueProviderOperations==0 && PushWindowModel.activePushWorkflows==0 && PushWindowModel.activePreparationReads==0 && StashWindowModel.activePreparations==0 && StashWindowController.activeChildReleases==0 && ResolveWindowModel.activeOperations==0 && ResolveWindowController.activeReleases==0 && ClientHookSession.activeOperations==0 && ClientHookProcessPool.shared.activeScripts==0 && NSApp.windows.allSatisfy({$0.attachedSheet==nil && $0.sheetParent==nil && !$0.isVisible}) {return}
   try await Task.sleep(nanoseconds:10_000_000)
  }
  let windows=NSApp.windows.map{"\(type(of:$0)) title=\($0.title.debugDescription) visible=\($0.isVisible) parent=\(String(describing:$0.sheetParent?.title)) child=\(String(describing:$0.attachedSheet?.title))"}.joined(separator:"; ")
  throw NSError(domain:"Switch/Reset family owned work or sheets survived cleanup: operations=\(SwitchProgressWindowModel.activeOperations)/\(ResetProgressWindowModel.activeOperations),releases=\(SwitchWindowController.activeChildReleases)/\(ResetWindowController.activeChildReleases),reads=\(SwitchWindowModel.activeReads)/\(ResetWindowModel.activeReads),windows=\(windows)",code:1)
 }
 @MainActor static func main()async throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let geometrySuite="TurtleGit.SwitchResetProgress.Geometry."+UUID().uuidString,geometryPreferences=UserDefaults(suiteName:geometrySuite)!
  DialogGeometry.install(preferences:geometryPreferences)
  defer{DialogGeometry.install(preferences:.standard);geometryPreferences.removePersistentDomain(forName:geometrySuite)}
  let normal=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
  let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitSwitchResetProgressOrder(_:relativeTo:)))!
  method_exchangeImplementations(normal,hidden);defer{method_exchangeImplementations(normal,hidden)}
  do {
  switch ProcessInfo.processInfo.environment["TURTLEGIT_SWITCH_RESET_PROGRESS_CASE"]! {
''' + '\n'.join('case "'+key+'": '+call for key, call in CASES.items()) + '''
  default:fatalError("Unknown Switch/Reset progress case")
  }
  } catch {
   NSApp.windows.forEach{window in if let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.abort);sheet.orderOut(nil)};window.close()}
   try? await drain();throw error
  }
  NSApp.windows.forEach{$0.close()};try await drain()
  print("PASS: Switch/Reset progress native case completed")
 }
}
'''
if not main.is_file() or main.read_text() != contents:
    main.write_text(contents)
receiver = build_receiver(root, fixtures+[main], sources)
with tempfile.TemporaryDirectory(prefix='turtlegit-switch-reset-progress-family-') as temporary:
    folder = Path(temporary)
    environment = dict(os.environ, DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for key in ['GIT_CONFIG_PARAMETERS', 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_AUTHOR_DATE', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL', 'GIT_COMMITTER_DATE', 'TURTLEGIT_ADD_LIST_CAPTURE']:
        environment.pop(key, None)
    for case in args.only or CASES:
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            directory = folder/(case+str(index)); directory.mkdir()
            config = directory/'global.config'; config.write_text('')
            environment.update(GIT_CONFIG_GLOBAL=str(config), XDG_CONFIG_HOME=str(directory/'xdg'), TURTLEGIT_SWITCH_RESET_PROGRESS_CASE=case)
            print('Checking Switch/Reset progress '+case+' with '+str(git), flush=True)
            result = run_receiver([str(receiver), str(directory), str(git.absolute())], cwd=root, env=environment,
                                  capture_output=True, text=True, timeout_sample=directory/'timeout.sample.txt')
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if 'PASS: Switch/Reset progress native case completed' not in result.stdout:
                raise SystemExit('Switch/Reset progress receiver exited before completion: '+case)
