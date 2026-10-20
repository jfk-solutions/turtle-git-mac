#!/usr/bin/env python3
"""Grouped native FullRowSelect adapter and actual dialog-family acceptance."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['adapter', 'families'])
parser.add_argument('--capture-dir', type=Path)
parser.add_argument('--capture-only', action='store_true', help='Capture the prepared adapter tables without repeating behavioral checks')
args = parser.parse_args()
if args.capture_only and not args.capture_dir:
    parser.error('--capture-only requires --capture-dir')
root = Path(__file__).resolve().parent.parent
sources = root/'build/qa/list-selection-sources'
sources.mkdir(parents=True, exist_ok=True)
fixtures = []
for name in ['list-selection-native-2026-10-20.swift', 'list-selection-families-native-2026-10-20.swift']:
    destination = sources/name
    content = (root/'docs/qa'/name).read_text()
    if not destination.exists() or destination.read_text() != content:
        destination.write_text(content)
    fixtures.append(destination)
main = sources/'ListSelectionMain.swift'
content = r'''import AppKit
import ObjectiveC
private extension NSWindow {
 @objc func turtleGitSelectionOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;setFrameOrigin(.init(x:-16000,y:-16000));turtleGitSelectionOrder(place,relativeTo:number)
 }
}
@main struct ListSelectionMain {
 @MainActor static func drain()async throws {
  for _ in 0..<3000 {
   if CommitContainingReferencesWindowController.activeOperations==0 && RepositoryBrowserWindowModel.activeOperations==0 && SynchronizationWindowModel.activeInlineOperations==0 && LFSLocksWindowModel.activeOperations==0 && NSApp.windows.allSatisfy({!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}){return}
   try await Task.sleep(nanoseconds:10_000_000)
  }
  throw ListSelectionVerification.Failure(description:"Owned list-selection work/windows survived cleanup")
 }
 @MainActor static func main()async throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitSelectionOrder(_:relativeTo:)))!
  method_exchangeImplementations(original,hidden);defer{method_exchangeImplementations(original,hidden)}
  do {
   let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
   if CommandLine.arguments[3]=="adapter" {
    let capture=CommandLine.arguments[4].isEmpty ? nil:URL(fileURLWithPath:CommandLine.arguments[4])
    try await ListSelectionVerification.verify(root:root,captureDirectory:capture,captureOnly:CommandLine.arguments[5]=="1")
   }else{try await ListSelectionFamilyVerification.verify(root:root,git:git)}
  }catch{
   let failure=error;NSApp.windows.forEach{window in if let parent=window.sheetParent{parent.endSheet(window,returnCode:.abort)};window.close()}
   do{try await drain()}catch{throw ListSelectionVerification.Failure(description:"\(failure); cleanup: \(error)")};throw failure
  }
  NSApp.windows.forEach{$0.close()};try await drain();print("PASS: native list selection completed")
 }
}
'''
if not main.exists() or main.read_text() != content:
    main.write_text(content)
receiver = build_receiver(root, fixtures+[main], sources)
with tempfile.TemporaryDirectory(prefix='turtlegit-list-selection-') as temporary:
    folder = Path(temporary)
    base = {key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
    base.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for case in (['adapter'] if args.capture_only else [args.only] if args.only else ['adapter', 'families']):
        requested = args.git or [Path('/usr/bin/git')]
        for index, git in enumerate(requested[:1] if case == 'adapter' else requested):
            directory = folder/(case+str(index));directory.mkdir()
            config = directory/'global.config';config.write_text('')
            home = directory/'home';home.mkdir(mode=0o700)
            private_tmp = directory/'tmp';private_tmp.mkdir(mode=0o700)
            env = dict(base, GIT_CONFIG_GLOBAL=str(config), XDG_CONFIG_HOME=str(directory/'xdg'), CFFIXED_USER_HOME=str(home), TMPDIR=str(private_tmp))
            capture = str(args.capture_dir.absolute()) if args.capture_dir and index == 0 else ''
            print('Checking native list-selection '+case+' with '+str(git), flush=True)
            result = run_receiver([str(receiver), str(directory), str(git.absolute()), case, capture, '1' if args.capture_only else '0'], cwd=root, env=env, capture_output=True, text=True, timeout_sample=directory/'timeout.sample.txt')
            print(result.stdout, end='');print(result.stderr, end='');result.check_returncode()
            if 'PASS: native list selection completed' not in result.stdout:
                raise SystemExit('List-selection receiver exited before completion')
