#!/usr/bin/env python3
"""Grouped main Sync and Add/Resolve source progress with owned hidden receivers."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

CASES = {
    'sync-inline': 'try await SyncInlineProgressVerification.verify()',
    'add-resolve': 'try await AddResolveProgressVerification.verify()',
    'sync-retained': 'try await InlineFileProgressMain.retainedSync()',
    'resolve-retained': 'try await ResolveProgressVerification.verify()',
    'add-list-retained': 'try await AddListFamilyVerification.verify()',
}
FILES = [
    'sync-inline-progress-native-2026-10-19.swift',
    'add-resolve-progress-native-2026-10-19.swift',
    'synchronization-native-2026-10-11.swift',
    'synchronization-apply-native-2026-10-11.swift',
    'synchronization-email-native-2026-10-11.swift',
    'resolve-progress-native-2026-10-14.swift',
    'add-list-family-native-2026-10-15.swift',
]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=CASES, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
sources = root/'build/qa/inline-file-progress-sources'
sources.mkdir(parents=True, exist_ok=True)
fixtures = []
for filename in FILES:
    target = sources/filename
    contents = (root/'docs/qa'/filename).read_text().replace('@main ', '', 1)
    if not target.is_file() or target.read_text() != contents:
        target.write_text(contents)
    fixtures.append(target)
main = sources/'InlineFileProgressMain.swift'
contents = r'''import AppKit
import ObjectiveC
import TurtleGitCore
private extension NSWindow {
 @objc func turtleGitInlineFileOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;turtleGitInlineFileOrder(place,relativeTo:number)
 }
}
@main struct InlineFileProgressMain {
 @MainActor static func retainedSync()async throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
  _ = try await repo.run(["init","-b","main"])
  for (key,value) in [("user.name","Retained progress QA"),("user.email","retained@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
  try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"base")
  let base=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
  _ = try await repo.run(["remote","add","origin","/tmp/private-unused-remote"])
  _ = try await repo.run(["config","branch.main.remote","origin"]);_ = try await repo.run(["config","branch.main.merge","refs/heads/review"])
  _ = try await repo.run(["update-ref","refs/remotes/origin/review",base])
  try Data("outgoing\n".utf8).write(to:root.appendingPathComponent("outgoing"));try await repo.stage(["outgoing"]);_ = try await repo.commit(message:"outgoing")
  let suite="TurtleGit.RetainedInline."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
  defer{prefs.removePersistentDomain(forName:suite);DialogGeometry.install(preferences:.standard)}
  prefs.set(0,forKey:"AutoCloseGitProgress");DialogGeometry.install(preferences:prefs)
  do {
   try await SynchronizationVerification.verifyTransport(repo:repo,root:root,preferences:prefs)
   try await SynchronizationVerification.verifyStash(root:root,preferences:prefs)
   try await SynchronizationVerification.verifySubmodules(root:root,preferences:prefs)
   try await drainRetainedSync()
  } catch {
   NSApp.windows.forEach{$0.close()}
   try? await drainRetainedSync()
   throw error
  }
 }
 struct Failure:Error,CustomStringConvertible{let description:String}
 @MainActor static func drainRetainedSync()async throws {
  for _ in 0..<3000 {
   if SynchronizationWindowModel.activeInlineOperations==0 && SynchronizationWindowController.activeInlineReleases==0 && StashWindowModel.activePreparations==0 && StashWindowController.activeChildReleases==0 && SubmoduleSyncWindowModel.activeOperations==0 && SubmoduleUpdateWindowModel.activeReads==0 && SubmoduleUpdateProgressWindowModel.activeOperations==0 && SubmoduleUpdateProgressWindowController.activeChildReleases==0 && LocalGitCommandProgress.activeOperations==0 && NSApp.windows.allSatisfy({!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}) {return}
   try await Task.sleep(nanoseconds:10_000_000)
  }
  throw Failure(description:"Retained Sync inline/preparation/child operations or windows survived cleanup")
 }
 @MainActor static func main()async throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let normal=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
  let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitInlineFileOrder(_:relativeTo:)))!
  method_exchangeImplementations(normal,hidden);defer{method_exchangeImplementations(normal,hidden)}
  switch ProcessInfo.processInfo.environment["TURTLEGIT_INLINE_FILE_CASE"]! {
''' + '\n'.join('case "'+key+'": '+call for key, call in CASES.items()) + '''
  default:fatalError("Unknown inline/file progress case")
  }
  print("PASS: inline/file progress native case completed")
 }
}
'''
if not main.is_file() or main.read_text() != contents:
    main.write_text(contents)
receiver = build_receiver(root, fixtures+[main], sources)
with tempfile.TemporaryDirectory(prefix='turtlegit-inline-file-progress-') as temporary:
    folder = Path(temporary)
    environment = dict(os.environ, DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for key in ['GIT_CONFIG_PARAMETERS', 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_AUTHOR_DATE', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL', 'GIT_COMMITTER_DATE', 'TURTLEGIT_ADD_LIST_CAPTURE']:
        environment.pop(key, None)
    for case in args.only or CASES:
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            directory = folder/(case+str(index)); directory.mkdir()
            config = directory/'global.config'; config.write_text('')
            environment.update(GIT_CONFIG_GLOBAL=str(config), XDG_CONFIG_HOME=str(directory/'xdg'), TURTLEGIT_INLINE_FILE_CASE=case)
            if index == 0 and case in ['sync-inline', 'add-resolve']:
                environment['TURTLEGIT_PROGRESS_CAPTURES'] = str(root/'build/qa/progress-family-captures')
            else:
                environment.pop('TURTLEGIT_PROGRESS_CAPTURES', None)
            print('Checking inline/file progress '+case+' with '+str(git), flush=True)
            result = run_receiver([str(receiver), str(directory), str(git.absolute())], cwd=root, env=environment,
                                  capture_output=True, text=True, timeout_sample=directory/'timeout.sample.txt')
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if 'PASS: inline/file progress native case completed' not in result.stdout:
                raise SystemExit('Inline/file progress receiver exited before completion: '+case)
