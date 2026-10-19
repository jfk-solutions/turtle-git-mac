#!/usr/bin/env python3
"""Grouped native optional remote-reference engine snapshots, deletion and actual reader lifetime."""
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
sources = root/'build/qa/remote-reference-backend-native-sources'
sources.mkdir(parents=True, exist_ok=True)
fixture = root/'docs/qa/remote-reference-backend-native-2026-10-19.swift'
main = sources/'RemoteReferenceBackendFamilyMain.swift'
contents = r'''import AppKit
import ObjectiveC
import TurtleGitCore
private extension NSWindow {
 @objc func turtleGitRemoteReferenceBackendOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;turtleGitRemoteReferenceBackendOrder(place,relativeTo:number)
 }
}
@main struct RemoteReferenceBackendFamilyMain {
 @MainActor static func drain()async throws {
  for _ in 0..<3000 {
   if RemoteReferenceBackendVerification.drained() && NSApp.windows.allSatisfy({!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}) {return}
   try await Task.sleep(nanoseconds:10_000_000)
  }
  throw NSError(domain:"Remote-reference backend owned work/windows survived cleanup",code:1)
 }
 @MainActor static func main()async throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let suite="TurtleGit.RemoteReferenceBackend.Geometry."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
  DialogGeometry.install(preferences:prefs)
  defer{DialogGeometry.install(preferences:.standard);prefs.removePersistentDomain(forName:suite)}
  let normal=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
  let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitRemoteReferenceBackendOrder(_:relativeTo:)))!
  method_exchangeImplementations(normal,hidden);defer{method_exchangeImplementations(normal,hidden)}
  do { try await RemoteReferenceBackendVerification.verify() }
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
with tempfile.TemporaryDirectory(prefix='turtlegit-remote-reference-backend-native-') as temporary:
    folder = Path(temporary)
    config = folder/'global.config'; config.write_text('')
    environment = dict(os.environ, DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0', XDG_CONFIG_HOME=str(folder/'xdg'))
    for key in ['GIT_CONFIG_PARAMETERS', 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_AUTHOR_DATE', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL', 'GIT_COMMITTER_DATE']:
        environment.pop(key, None)
    result = run_receiver([str(receiver), str(folder), str(args.git.absolute()), str(helper)], cwd=root, env=environment, capture_output=True, text=True, timeout_sample=folder/'timeout.sample.txt')
    print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
    if 'PASS: native remote-reference helper listing/deletion/Sync snapshot and cancellation family' not in result.stdout:
        raise SystemExit('Remote-reference backend receiver exited before completion')
