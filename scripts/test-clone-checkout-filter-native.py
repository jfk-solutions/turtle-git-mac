#!/usr/bin/env python3
"""Grouped native Clone checkout filters, recursive work and owned process lifetime."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, default=Path('/usr/bin/git'))
parser.add_argument('--helper', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
helper = (args.helper or root/'build/libgit2-runtime/LibGit2/bin/turtlegit-libgit2').absolute()
sources = root/'build/qa/clone-checkout-filter-native-sources'
sources.mkdir(parents=True, exist_ok=True)
fixture = root/'docs/qa/clone-checkout-filter-native-2026-10-19.swift'
main = sources/'CloneCheckoutFilterFamilyMain.swift'
contents = r'''import AppKit
import ObjectiveC
import TurtleGitCore
private extension NSWindow {
 @objc func turtleGitCloneCheckoutFilterOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;turtleGitCloneCheckoutFilterOrder(place,relativeTo:number)
 }
}
@main struct CloneCheckoutFilterFamilyMain {
 @MainActor static func drain()async throws {
  for _ in 0..<3000 {
   if CloneCheckoutFilterVerification.drained() && NSApp.windows.allSatisfy({!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}) {return}
   try await Task.sleep(nanoseconds:10_000_000)
  }
  throw NSError(domain:"Clone checkout filter owned work/windows survived cleanup",code:1)
 }
 @MainActor static func main()async throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let suite="TurtleGit.CloneCheckoutFilter.Geometry."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
  DialogGeometry.install(preferences:prefs)
  defer{DialogGeometry.install(preferences:.standard);prefs.removePersistentDomain(forName:suite)}
  let normal=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
  let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitCloneCheckoutFilterOrder(_:relativeTo:)))!
  method_exchangeImplementations(normal,hidden);defer{method_exchangeImplementations(normal,hidden)}
  do { try await CloneCheckoutFilterVerification.verify() }
  catch {
   NSApp.windows.forEach{window in if let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.abort);sheet.close()};window.close()}
   try? await drain();throw error
  }
  NSApp.windows.forEach{$0.close()};try await drain()
 }
}
'''
if not main.exists() or main.read_text() != contents:
    main.write_text(contents)
receiver = build_receiver(root, [fixture, main], sources)
with tempfile.TemporaryDirectory(prefix='turtlegit-clone-checkout-filter-native-') as temporary:
    folder = Path(temporary)
    private_temporary = folder/'temporary'; private_temporary.mkdir(mode=0o700)
    config = folder/'global.config'; config.write_text('')
    environment = dict(os.environ, TMPDIR=str(private_temporary)+'/', DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0', XDG_CONFIG_HOME=str(folder/'xdg'), TURTLEGIT_CLONE_FILTER_MARKER='private-clone-context')
    for key in ['GIT_CONFIG_PARAMETERS', 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_AUTHOR_DATE', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL', 'GIT_COMMITTER_DATE', 'GIT_LFS_SKIP_SMUDGE', 'GIT_LFS_SKIP_DOWNLOAD_ERRORS']:
        environment.pop(key, None)
    result = run_receiver([str(receiver), str(folder), str(args.git.absolute()), str(helper)], cwd=root, env=environment, capture_output=True, text=True, timeout_sample=folder/'timeout.sample.txt')
    print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
    if 'PASS: native Clone custom/git-lfs checkout filters, recursive/captured options, no-checkout/bare, required failure and owned cancellation' not in result.stdout:
        raise SystemExit('Clone checkout filter receiver exited before completion')
