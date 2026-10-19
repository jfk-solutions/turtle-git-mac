#!/usr/bin/env python3
"""Grouped native optional backend snapshots and owned Git transport prompts."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, default=Path('/usr/bin/git'))
parser.add_argument('--helper', type=Path)
parser.add_argument('--capture-directory', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
helper = (args.helper or root/'build/libgit2-runtime/LibGit2/bin/turtlegit-libgit2').absolute()
sources = root/'build/qa/libgit2-native-sources'
sources.mkdir(parents=True, exist_ok=True)
bridge = sources/'SVNPromptWindow.swift'
contents = 'import TurtleGitCore\n'+(root/'Sources/TurtleGitGitAskpass/SVNPromptWindow.swift').read_text()
if not bridge.exists() or bridge.read_text() != contents:
    bridge.write_text(contents)
fixture = sources/'LibGit2NativeVerification.swift'
contents = (root/'docs/qa/libgit2-native-2026-10-19.swift').read_text().replace('@main ', '', 1)
if not fixture.exists() or fixture.read_text() != contents:
    fixture.write_text(contents)
main = sources/'LibGit2NativeFamilyMain.swift'
contents = r'''import AppKit
import ObjectiveC
import TurtleGitCore
private extension NSWindow {
 @objc func turtleGitLibgit2Order(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;turtleGitLibgit2Order(place,relativeTo:number)
 }
}
@main struct LibGit2NativeFamilyMain {
 @MainActor static func main()async throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let suite="TurtleGit.Libgit2.Geometry."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
  DialogGeometry.install(preferences:prefs)
  defer{DialogGeometry.install(preferences:.standard);prefs.removePersistentDomain(forName:suite)}
  let normal=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
  let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitLibgit2Order(_:relativeTo:)))!
  method_exchangeImplementations(normal,hidden);defer{method_exchangeImplementations(normal,hidden)}
  do{try await GitLibGit2NativeVerification.main()}
  catch{
   NSApp.windows.forEach{window in if let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.abort);sheet.close()};window.close()}
   for _ in 0..<3000 {
    if CloneProgressWindowModel.activeOperations==0 && FetchProgressWindowModel.activeOperations==0 && NSApp.windows.allSatisfy({!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}) {break}
    try? await Task.sleep(nanoseconds:10_000_000)
   }
   throw error
  }
 }
}
'''
if not main.exists() or main.read_text() != contents:
    main.write_text(contents)
receiver = build_receiver(root, [bridge, fixture, main], sources)
with tempfile.TemporaryDirectory(prefix='turtlegit-libgit2-native-') as temporary:
    folder = Path(temporary)
    config = folder/'global.config'
    config.write_text('')
    environment = dict(os.environ, DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0', XDG_CONFIG_HOME=str(folder/'xdg'), TURTLEGIT_CERTIFICATE_FIXTURE=str(root/'Tests/TurtleGitCoreTests/Fixtures/Certificates/server.der'))
    if args.capture_directory:
        environment['TURTLEGIT_LIBGIT2_CAPTURE'] = str(args.capture_directory.absolute())
    else:
        environment.pop('TURTLEGIT_LIBGIT2_CAPTURE', None)
    for key in ['GIT_CONFIG_PARAMETERS', 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_AUTHOR_DATE', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL', 'GIT_COMMITTER_DATE']:
        environment.pop(key, None)
    result = run_receiver([str(receiver), str(folder), str(args.git.absolute()), str(helper)], cwd=root, env=environment, capture_output=True, text=True, timeout_sample=folder/'timeout.sample.txt')
    print(result.stdout, end='')
    print(result.stderr, end='')
    result.check_returncode()
