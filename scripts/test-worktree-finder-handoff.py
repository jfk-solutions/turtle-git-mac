#!/usr/bin/env python3
"""Owned Finder Worktree destination handoff and directly affected Worktree workflows."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

CASES = {
    'finder': ('worktree-finder-handoff-native-2026-10-19.swift', 'WorktreeFinderHandoffVerification.verify()', 'finder'),
    'family': ('worktree-family-native-2026-10-14.swift', 'WorktreeDialogVerification.verify()', 'family'),
    'progress': ('worktree-progress-native-2026-10-14.swift', 'WorktreeProgressVerification.verify()', 'progress'),
    'commands': ('worktree-commands-native-2026-10-18.swift', 'PrimaryCommandsVerification.verifyWorktreeCommands()', 'worktrees'),
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=CASES, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
generated = root/'build/qa/worktree-finder-native-sources'
generated.mkdir(parents=True, exist_ok=True)
fixtures = []
for name, _, _ in CASES.values():
    target = generated/name
    contents = (root/'docs/qa'/name).read_text().replace('@main ', '', 1)
    if not target.exists() or target.read_text() != contents:
        target.write_text(contents)
    fixtures.append(target)
main = generated/'WorktreeFinderMain.swift'
contents = r'''import AppKit
import ObjectiveC
struct PrimaryCommandsVerification {
 struct Failure:Error,CustomStringConvertible {let description:String}
 static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
 @MainActor static func wait(_ ready:()->Bool,line:Int = #line)async throws {
  for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
  throw Failure(description:"Primary command native state did not settle at \(line)")
 }
}
private extension NSWindow {
 @objc func turtleGitWorktreeFinderOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;turtleGitWorktreeFinderOrder(place,relativeTo:number)
 }
}
@main struct WorktreeFinderMain {
 @MainActor static func main() async throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let normal=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
  let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitWorktreeFinderOrder(_:relativeTo:)))!
  method_exchangeImplementations(normal,hidden)
  defer {method_exchangeImplementations(normal,hidden)}
  switch ProcessInfo.processInfo.environment["TURTLEGIT_WORKTREE_FINDER_CASE"]! {
''' + '\n'.join('case "'+key+'":try await '+value[1] for key,value in CASES.items()) + '''
  default:fatalError("Unknown Worktree Finder case")
  }
  print("PASS: owned Worktree Finder case completed")
 }
}
'''
if not main.exists() or main.read_text() != contents:
    main.write_text(contents)
receiver = build_receiver(root, fixtures+[root/'FinderSync/FinderSync.swift',main], generated)
with tempfile.TemporaryDirectory(prefix='turtlegit-worktree-finder-') as temporary:
    folder = Path(temporary)
    environment = dict(os.environ, DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for key in ['GIT_CONFIG_PARAMETERS', 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_AUTHOR_DATE', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL', 'GIT_COMMITTER_DATE']:
        environment.pop(key, None)
    for case in args.only or CASES:
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            directory = folder/(case+str(index)); directory.mkdir()
            config = directory/'global.config'; config.write_text('')
            environment.update(GIT_CONFIG_GLOBAL=str(config), XDG_CONFIG_HOME=str(directory/'xdg'), TURTLEGIT_WORKTREE_FINDER_CASE=case)
            print('Checking Worktree '+case+' with '+str(git), flush=True)
            result = run_receiver([str(receiver), str(directory), str(git.absolute()), CASES[case][2]], cwd=root, env=environment,
                                  capture_output=True, text=True, timeout_sample=directory/'timeout.sample.txt')
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if 'PASS: owned Worktree Finder case completed' not in result.stdout:
                raise SystemExit('Worktree Finder receiver exited before completion: '+case)
