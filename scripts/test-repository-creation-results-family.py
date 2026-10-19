#!/usr/bin/env python3
"""Grouped Repository creation results command receipts, native recovery lifetime and retained Git/post-action behavior."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

CASES = {
    'clone': 'try await CloneResultsFamilyVerification.verify()',
    'init': 'try await CreateRepositoryFamilyVerification.verify()',
    'clone-retained': 'try await CloneCompletionVerification.verify()',
    'stream-retained': 'try await CloneStreamVerification.main()',
}
FILES = ['clone-results-family-native-2026-10-19.swift',
         'create-repository-family-native-2026-10-19.swift',
         'clone-completion-native-2026-10-16.swift',
         'clone-stream-native-2026-10-08.swift']
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=CASES, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
sources = root/'build/qa/repository-creation-results-family-sources'
sources.mkdir(parents=True, exist_ok=True)
fixtures = []
for filename in FILES:
    target = sources/filename
    contents = (root/'docs/qa'/filename).read_text().replace('@main ', '', 1)
    if not target.is_file() or target.read_text() != contents:
        target.write_text(contents)
    fixtures.append(target)
main = sources/'RepositoryCreationResultsFamilyMain.swift'
contents = r'''import AppKit
import ObjectiveC
import TurtleGitCore
private extension NSWindow {
 @objc func turtleGitRepositoryCreationResultsOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;turtleGitRepositoryCreationResultsOrder(place,relativeTo:number)
 }
}
@main struct RepositoryCreationResultsFamilyMain {
 @MainActor static func drain()async throws {
  for _ in 0..<3000 {
   if CloneWindowModel.activeOperations==0 && CloneProgressWindowModel.activeOperations==0 && CloneWindowController.activeChildReleases==0 && CreateRepositoryWindowModel.activeOperations==0 && CreateRepositoryWindowController.activeReleases==0 && LocalGitCommandProgress.activeOperations==0 && LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeHistoryDeletions==0 && LogWindowModel.activeFileOpenReads==0 && LogWindowModel.activeActionReads==0 && LogWindowModel.activeReferenceReads==0 && LogWindowModel.activeWorkingCommandReads==0 && NSApp.windows.allSatisfy({$0.attachedSheet==nil && $0.sheetParent==nil && !$0.isVisible}) {return}
   try await Task.sleep(nanoseconds:10_000_000)
  }
  let windows=NSApp.windows.map{"\(type(of:$0)) title=\($0.title.debugDescription) visible=\($0.isVisible) parent=\(String(describing:$0.sheetParent?.title)) child=\(String(describing:$0.attachedSheet?.title))"}.joined(separator:"; ")
  throw NSError(domain:"Creation owned work/sheets survived cleanup: options=\(CloneWindowModel.activeOperations),progress=\(CloneProgressWindowModel.activeOperations),init=\(CreateRepositoryWindowModel.activeOperations),releases=\(CloneWindowController.activeChildReleases)/\(CreateRepositoryWindowController.activeReleases),windows=\(windows)",code:1)
 }
 @MainActor static func main()async throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let geometrySuite="TurtleGit.RepositoryCreationResults.Geometry."+UUID().uuidString,geometryPreferences=UserDefaults(suiteName:geometrySuite)!
  DialogGeometry.install(preferences:geometryPreferences)
  defer{DialogGeometry.install(preferences:.standard);geometryPreferences.removePersistentDomain(forName:geometrySuite)}
  let normal=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
  let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitRepositoryCreationResultsOrder(_:relativeTo:)))!
  method_exchangeImplementations(normal,hidden);defer{method_exchangeImplementations(normal,hidden)}
  do {
  switch ProcessInfo.processInfo.environment["TURTLEGIT_REPOSITORY_CREATION_RESULTS_CASE"]! {
''' + '\n'.join('case "'+key+'": '+call for key, call in CASES.items()) + '''
  default:fatalError("Unknown Repository creation results progress case")
  }
  } catch {
   NSApp.windows.forEach{window in if let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.abort);sheet.orderOut(nil)};window.close()}
   try? await drain();throw error
  }
  NSApp.windows.forEach{$0.close()};try await drain()
  print("PASS: Repository creation results progress native case completed")
 }
}
'''
if not main.is_file() or main.read_text() != contents:
    main.write_text(contents)
receiver = build_receiver(root, fixtures+[main], sources)
with tempfile.TemporaryDirectory(prefix='turtlegit-repository-creation-results-family-') as temporary:
    folder = Path(temporary)
    environment = dict(os.environ, DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for key in ['GIT_CONFIG_PARAMETERS', 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_AUTHOR_DATE', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL', 'GIT_COMMITTER_DATE', 'TURTLEGIT_ADD_LIST_CAPTURE']:
        environment.pop(key, None)
    for case in args.only or CASES:
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            directory = folder/(case+str(index)); directory.mkdir()
            config = directory/'global.config'; config.write_text('')
            environment.update(GIT_CONFIG_GLOBAL=str(config), XDG_CONFIG_HOME=str(directory/'xdg'), TURTLEGIT_REPOSITORY_CREATION_RESULTS_CASE=case)
            print('Checking Repository creation results progress '+case+' with '+str(git), flush=True)
            result = run_receiver([str(receiver), str(directory), str(git.absolute())], cwd=root, env=environment,
                                  capture_output=True, text=True, timeout_sample=directory/'timeout.sample.txt')
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if 'PASS: Repository creation results progress native case completed' not in result.stdout:
                raise SystemExit('Repository creation results progress receiver exited before completion: '+case)
