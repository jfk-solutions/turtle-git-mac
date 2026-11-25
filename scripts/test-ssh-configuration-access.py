#!/usr/bin/env python3
"""Cached native SSH configuration grant UI, selection and owned-sheet lifecycle."""
import argparse
import json
import os
from pathlib import Path
import shutil
import tempfile

from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
sources = root / 'build/qa/ssh-configuration-access-native-sources'
sources.mkdir(parents=True, exist_ok=True)
main = sources / 'SSHConfigurationAccessMain.swift'
contents = r'''import AppKit
import ObjectiveC
import TurtleGitCore
private extension NSWindow {
 @objc func sshConfigurationPrivateOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));sshConfigurationPrivateOrder(place,relativeTo:number)
 }
}
@main struct SSHConfigurationAccessMain {
 struct Failure:Error,CustomStringConvertible {let description:String}
 @MainActor static func drain()async throws {
  for _ in 0..<3000 {
   if SSHConfigurationAccessWindowController.activeOperations==0 && NetworkSettingsModel.activeReads==0 && NetworkSettingsModel.activeSaves==0 && NetworkSettingsModel.activeSSHChoosers==0 && NetworkSettingsModel.activeSheetReleases==0 && PathEntryField.Coordinator.activeReads==0 && NSApp.windows.allSatisfy({!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}) {return}
   try await Task.sleep(nanoseconds:10_000_000)
  }
  let windows=NSApp.windows.map{"\(type(of:$0)) visible=\($0.isVisible) parent=\($0.sheetParent != nil) child=\($0.attachedSheet != nil)"}.joined(separator:"; ")
  throw Failure(description:"SSH configuration owned cleanup did not drain: grants=\(SSHConfigurationAccessWindowController.activeOperations),Network=\(NetworkSettingsModel.activeReads)/\(NetworkSettingsModel.activeSaves)/\(NetworkSettingsModel.activeSSHChoosers)/\(NetworkSettingsModel.activeSheetReleases),windows=\(windows)")
 }
 @MainActor static func main()async throws {
  NSApp.setActivationPolicy(.prohibited)
  let suite="TurtleGit.SSHConfiguration.Geometry."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
  DialogGeometry.install(preferences:prefs)
  defer{DialogGeometry.install(preferences:.standard);prefs.removePersistentDomain(forName:suite)}
  let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
  let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.sshConfigurationPrivateOrder(_:relativeTo:)))!
  method_exchangeImplementations(original,hidden);defer{method_exchangeImplementations(original,hidden)}
  var failure:Error?
  do {try await SSHConfigurationAccessVerification.verify(base:URL(fileURLWithPath:CommandLine.arguments[1]),git:URL(fileURLWithPath:CommandLine.arguments[2]))}
  catch{failure=error}
  NativeOwnedWindowCleanup.close(NSApp.windows,returnCode:failure==nil ? .cancel:.abort)
  do {try await drain()}catch{throw Failure(description:"\(String(describing:failure)); cleanup: \(error)")}
  if let failure{throw failure}
  guard !NSApp.isActive else{throw Failure(description:"Private SSH configuration receiver became active")}
  print("PASS: SSH configuration access receiver and owned cleanup completed")
 }
}
'''
if not main.is_file() or main.read_text() != contents:
    main.write_text(contents)
receiver = build_receiver(root, [root/'docs/qa/ssh-configuration-access-native-2026-11-25.swift', main], sources)
results = []
for index, selected_git in enumerate(args.git or [Path('/usr/bin/git'), root/'build/git-runtime/Git/bin/git']):
    git = selected_git.absolute()
    with tempfile.TemporaryDirectory(prefix='turtlegit-ssh-configuration-native-') as temporary:
        private = Path(temporary).resolve()
        for name in ('home', 'preferences', 'temporary', 'xdg'):
            (private/name).mkdir(mode=0o700)
        config = private/'global.config'; config.write_text('')
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith('GIT_') and not (key.startswith('TURTLEGIT_') and 'CAPTURE' in key)}
        environment.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),
                           GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                           HOME=str(private/'home'), CFFIXED_USER_HOME=str(private/'preferences'),
                           TMPDIR=str(private/'temporary')+'/', XDG_CONFIG_HOME=str(private/'xdg'))
        print('Checking SSH configuration access UI with '+str(git), flush=True)
        try:
            result = run_receiver([str(receiver), str(private/'fixture'), str(git)], cwd=root, env=environment,
                                  capture_output=True, text=True, timeout=180, timeout_sample=private/'timeout.sample.txt')
            print(result.stdout, end=''); print(result.stderr, end='')
            passed = result.returncode == 0 and 'PASS: SSH configuration access receiver and owned cleanup completed' in result.stdout
            results.append(dict(git=str(git), returncode=result.returncode, passed=passed))
            (root/'build/qa/ssh-configuration-access-native-results.json').write_text(json.dumps(results, indent=2)+'\n')
            result.check_returncode()
            if not passed:
                raise RuntimeError('SSH configuration receiver exited without final behavioral/drain assertions')
        except BaseException:
            evidence = Path(tempfile.mkdtemp(prefix='ssh-configuration-failed-'+str(index)+'-', dir=root/'build/qa'))
            shutil.copytree(private, evidence, dirs_exist_ok=True, symlinks=True)
            print('Retained private SSH configuration failure: '+str(evidence), flush=True)
            raise
