#!/usr/bin/env python3
"""Grouped native folded pane input, ghost deletion and retained typing/history."""
import argparse
import ast
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
cases = ['navigation', 'editing', 'ownership', 'typing', 'history', 'words', 'word-editing', 'word-ownership']
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=cases, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
cleanup_tree=ast.parse((root/'scripts/test-log-file-drags.py').read_text())
cleanup=next(item for item in cleanup_tree.body if isinstance(item,ast.FunctionDef) and item.name=='retire_owned_helpers')
namespace=dict(os=os,signal=signal,time=time,subprocess=subprocess,Path=Path)
exec(compile(ast.Module(body=[cleanup],type_ignores=[]),'<owned pane-input helpers>','exec'),namespace)
retire_owned_helpers=namespace['retire_owned_helpers']
inputs = root/'build/qa/merge-pane-input-sources'
inputs.mkdir(parents=True, exist_ok=True)
sources = []
for name in ['merge-pane-input-native-2026-10-19.swift', 'merge-word-input-native-2026-10-20.swift', 'merge-typing-native-2026-10-16.swift',
             'merge-edit-history-native-2026-10-18.swift', 'merge-menu-lifecycle-native-2026-10-16.swift',
             'two-pane-engine-native-2026-10-12.swift', 'three-pane-engine-native-2026-10-12.swift']:
    target = inputs/name
    text = (root/'docs/qa'/name).read_text().replace('@main ', '', 1)
    if not target.is_file() or target.read_text() != text:
        target.write_text(text)
    sources.append(target)
main = inputs/'MergePaneInputMain.swift'
text = r'''import AppKit
import ObjectiveC
private extension NSWindow {
 @objc func turtleGitPaneInputOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;setFrameOrigin(.init(x:-12000,y:-12000))
  turtleGitPaneInputOrder(place,relativeTo:number)
 }
 @objc func turtleGitPaneInputConstrain(_ frame:NSRect,to screen:NSScreen?)->NSRect {frame}
}
@main struct MergePaneInputMain {
 @MainActor static func main()async throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
  let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitPaneInputOrder(_:relativeTo:)))!
  let constrain=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:)))!
  let offscreen=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitPaneInputConstrain(_:to:)))!
  method_exchangeImplementations(original,hidden)
  method_exchangeImplementations(constrain,offscreen)
  defer{method_exchangeImplementations(original,hidden);method_exchangeImplementations(constrain,offscreen)}
  let test=ProcessInfo.processInfo.environment["TURTLEGIT_PANE_INPUT_CASE"]!
  do {
   switch test {
   case "typing":try await MergeTypingVerification.verify()
   case "history":try await MergeEditHistoryVerification.verify()
   case "words","word-editing","word-ownership":try await MergeWordInputVerification.verify(test)
   default:try await MergePaneInputVerification.verify(test)
   }
   try await MergePaneInputVerification.drain()
  } catch {
   let failure=error
   for window in NSApp.windows {if let parent=window.sheetParent {parent.endSheet(window,returnCode:.cancel)};window.close()}
   do{try await MergePaneInputVerification.drain()}catch{throw MergePaneInputVerification.Failure(description:"\(failure); grouped cleanup: \(error)")}
   throw failure
  }
  print("PASS: pane input native case completed")
 }
}
'''
if not main.is_file() or main.read_text() != text:
    main.write_text(text)
receiver = build_receiver(root, sources+[main], inputs)
results=[]
with tempfile.TemporaryDirectory(prefix='turtlegit-pane-input-') as temporary:
    base = {key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
    for key in ['TURTLEGIT_WRAP_CAPTURE', 'TURTLEGIT_MENU_CAPTURE', 'TURTLEGIT_VIEW_CAPTURE']:
        base.pop(key, None)
    base.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for case in args.only or cases:
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            context=Path(temporary)/(case+str(index));context.mkdir()
            for name in ['fixture','preferences','temporary','xdg','home']:(context/name).mkdir(mode=0o700)
            config=context/'global.config';config.write_text('')
            env=dict(base,GIT_CONFIG_GLOBAL=str(config),XDG_CONFIG_HOME=str(context/'xdg'),TMPDIR=str(context/'temporary')+'/',CFFIXED_USER_HOME=str(context/'preferences'),HOME=str(context/'home'),TURTLEGIT_PANE_INPUT_CASE=case)
            git=git.absolute();passed=False;retained=False
            def retain():
                target=root/'build/qa/native-pane-input-failures';target.mkdir(parents=True,exist_ok=True)
                evidence=Path(tempfile.mkdtemp(prefix=case+'-',dir=target))
                shutil.copytree(context,evidence,dirs_exist_ok=True,symlinks=True)
                print('Retained private pane-input evidence: '+str(evidence),flush=True)
            print('Checking pane input '+case+' with '+str(git), flush=True)
            try:
                result=run_receiver([str(receiver),str(context/'fixture'),str(git)],cwd=root,env=env,capture_output=True,text=True,timeout=300,timeout_sample=context/'timeout.sample.txt')
                (context/'stdout.log').write_text(result.stdout);(context/'stderr.log').write_text(result.stderr)
                print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
                if 'PASS: pane input native case completed' not in result.stdout:raise RuntimeError('Pane input receiver exited before completion: '+case)
                passed=True;results.append(dict(case=case,git=str(git),exit_code=result.returncode,passed=True))
                (root/'build/qa/merge-pane-input-native-results.json').write_text(json.dumps(results,indent=2)+'\n')
            except BaseException:
                retain();retained=True;raise
            finally:
                try:
                    approved={str(git.resolve())}
                    selected=subprocess.run(['/usr/bin/xcrun','--find','git'],capture_output=True,text=True,timeout=10)
                    if selected.returncode==0:approved.add(str(Path(selected.stdout.strip()).resolve()))
                    helpers=root/'build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers'
                    approved.update(str(path.resolve()) for path in helpers.rglob('*') if path.is_file() and os.access(path,os.X_OK))
                    needed=retire_owned_helpers(context,approved)
                    if passed and needed:raise RuntimeError('Successful pane-input receiver left owned helpers running')
                except BaseException:
                    if not retained:retain()
                    raise
