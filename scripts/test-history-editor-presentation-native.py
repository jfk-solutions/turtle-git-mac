#!/usr/bin/env python3
"""Grouped native Blame rendering, Graph presentation and conflict inspection."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

CASES = {
    'blame': ('blame-rendering-native-2026-10-20.swift', 'BlameRenderingVerification'),
    'graph': ('graph-presentation-native-2026-10-20.swift', 'GraphPresentationVerification'),
    'merge': ('merge-conflict-inspection-native-2026-10-20.swift', 'MergeConflictInspectionVerification'),
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=CASES, action='append')
parser.add_argument('--capture-dir', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
sources = root/'build/qa/history-editor-presentation-sources'
sources.mkdir(parents=True, exist_ok=True)
main = sources/'HistoryEditorPresentationMain.swift'
contents = r'''import AppKit
import ObjectiveC
private extension NSWindow {
 @objc func turtleGitHistoryEditorOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;setFrameOrigin(.init(x:-16000,y:-16000));turtleGitHistoryEditorOrder(place,relativeTo:number)
 }
}
@main struct HistoryEditorPresentationMain {
 @MainActor static func drain()async throws {
  for _ in 0..<3000 {
   if BlameWindowModel.activeHistoryOperations==0 && BlameWindowModel.activeSyntaxRequests==0 && BlameDocumentOpener.activeReads==0 && RevisionGraphWindowModel.activeOperations==0 && RevisionGraphFilterController.activeOperations==0 && RevisionGraphFindController.activeOperations==0 && MergeEditorOpenWorkflow.activeSaves==0 && NSApp.windows.allSatisfy({!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}) {return}
   try await Task.sleep(nanoseconds:10_000_000)
  }
  throw NSError(domain:"History/editor owned work or windows survived cleanup",code:1)
 }
 @MainActor static func closeWindows() {
  for window in NSApp.windows {
   if let child=window.attachedSheet {window.endSheet(child,returnCode:.abort);child.close()}
   if let parent=window.sheetParent {parent.endSheet(window,returnCode:.abort)}
   window.close()
  }
 }
 @MainActor static func main()async throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let suite="TurtleGit.HistoryEditor.Geometry."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
  DialogGeometry.install(preferences:prefs)
  defer {DialogGeometry.install(preferences:.standard);prefs.removePersistentDomain(forName:suite)}
  let normal=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitHistoryEditorOrder(_:relativeTo:)))!
  method_exchangeImplementations(normal,hidden);defer{method_exchangeImplementations(normal,hidden)}
  let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
  do {
   switch CommandLine.arguments[3] {
''' + '\n'.join('   case "'+case+'":try await '+enum+'.verify(root:root,git:git)' for case, (_, enum) in CASES.items()) + r'''
   default:throw NSError(domain:"Unknown history/editor case",code:1)
   }
  } catch {
   let failure=error;closeWindows()
   do {try await drain()}catch {throw NSError(domain:"\(failure); cleanup: \(error)",code:1)}
   throw failure
  }
  closeWindows();try await drain();print("PASS: native history/editor presentation completed")
 }
}
'''
if not main.exists() or main.read_text() != contents:
    main.write_text(contents)
receiver = build_receiver(root, [root/'docs/qa'/name for name, _ in CASES.values()]+[main], sources)
with tempfile.TemporaryDirectory(prefix='turtlegit-history-editor-') as temporary:
    folder = Path(temporary)
    base = {key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
    base.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for case in args.only or CASES:
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            directory = folder/(case+str(index));directory.mkdir()
            config = directory/'global.config';config.write_text('')
            home = directory/'home';home.mkdir(mode=0o700)
            private_tmp = directory/'tmp';private_tmp.mkdir(mode=0o700)
            env = dict(base, GIT_CONFIG_GLOBAL=str(config), XDG_CONFIG_HOME=str(directory/'xdg'), CFFIXED_USER_HOME=str(home), TMPDIR=str(private_tmp)+'/')
            if args.capture_dir and index == 0:
                env['TURTLEGIT_HISTORY_EDITOR_CAPTURE'] = str(args.capture_dir.absolute())
            print('Checking history/editor '+case+' with '+str(git), flush=True)
            result = run_receiver([str(receiver), str(directory), str(git.absolute()), case], cwd=root, env=env, capture_output=True, text=True, timeout_sample=directory/'timeout.sample.txt')
            print(result.stdout, end='');print(result.stderr, end='');result.check_returncode()
            if 'PASS: native history/editor presentation completed' not in result.stdout:
                raise SystemExit('History/editor receiver exited before completion: '+case)
