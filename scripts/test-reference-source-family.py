#!/usr/bin/env python3
"""Grouped source reference-browser and remote-tag native workflows."""
import argparse
import ast
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
from native_receiver import build_receiver,run_receiver

cases={
 'filters':('reference-filter-native-2026-11-05.swift','ReferenceFilterVerification'),
 'source':('reference-source-native-2026-10-17.swift','ReferenceSourceVerification'),
 'presentation':('reference-presentation-native-2026-10-16.swift','ReferencePresentationVerification'),
 'targets':('reference-menu-targets-native-2026-10-16.swift','ReferenceMenuTargetsVerification'),
 'tags':('remote-tags-native-2026-10-09.swift','RemoteTagVerification'),
 'owned':('remote-management-owned-native-2026-10-16.swift','RemoteManagementOwnedVerification')}
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--git',type=Path,action='append')
p.add_argument('--only',choices=cases,action='append')
p.add_argument('--captures',type=Path)
args=p.parse_args();root=Path(__file__).resolve().parent.parent
# Share the established exact-image/private-resource helper ownership rule.
cleanup_tree=ast.parse((root/'scripts/test-log-file-drags.py').read_text())
cleanup=next(node for node in cleanup_tree.body if isinstance(node,ast.FunctionDef) and node.name=='retire_owned_helpers')
namespace=dict(os=os,signal=signal,time=time,subprocess=subprocess,Path=Path)
exec(compile(ast.Module(body=[cleanup],type_ignores=[]),'<owned reference helpers>','exec'),namespace)
retire_owned_helpers=namespace['retire_owned_helpers']
inputs=root/'build/qa/reference-source-family-inputs';inputs.mkdir(parents=True,exist_ok=True)
sources=[]
for filename,_ in cases.values():
    path=inputs/filename;text=(root/'docs/qa'/filename).read_text().replace('@main ','',1)
    if not path.is_file() or path.read_text()!=text:path.write_text(text)
    sources.append(path)
main=inputs/'ReferenceSourceMain.swift'
text='''import AppKit
import ObjectiveC
private extension NSWindow {
 @objc func turtleGitReferenceOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;setFrameOrigin(.init(x:-12000,y:-12000));turtleGitReferenceOrder(place,relativeTo:number)
 }
 @objc func turtleGitReferenceConstrain(_ frame:NSRect,to screen:NSScreen?)->NSRect {frame}
}
@main struct ReferenceSourceMain {
 @MainActor static func cleanup() async {
  RemoteManagementOwnedVerification.windows.forEach {$0.close()};RemoteManagementOwnedVerification.windows=[]
  for window in NSApp.windows {if let parent=window.sheetParent {parent.endSheet(window,returnCode:.cancel)};window.close()}
  await ReferenceSourceVerification.cleanup()
 }
 @MainActor static func main() async {
  NSApp.setActivationPolicy(.prohibited)
  let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
  let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitReferenceOrder(_:relativeTo:)))!
  let constrain=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:)))!
  let offscreen=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitReferenceConstrain(_:to:)))!
  let automated=ProcessInfo.processInfo.environment["TURTLEGIT_REFERENCE_SOURCE_CAPTURE"] == nil
  if automated {method_exchangeImplementations(original,hidden);method_exchangeImplementations(constrain,offscreen)}
  defer {if automated {method_exchangeImplementations(original,hidden);method_exchangeImplementations(constrain,offscreen)}}
  do {switch CommandLine.arguments[3] {
'''+''.join('case "'+case+'": try await '+kind+'.verify()\n' for case,(_,kind) in cases.items())+'''default:fatalError("Unknown reference case")
  };await cleanup()
  try ReferenceSourceVerification.require(ReferenceBrowserWindowModel.activeReads==0 && ReferenceBrowserWindowModel.activeMutations==0 && ReferenceBrowserWindowModel.activeFilters==0 && RemoteTagWindowModel.activeOperations==0 && !NSApp.windows.contains(where:{$0.isVisible || $0.sheetParent != nil || $0.attachedSheet != nil}),"Outstanding owned reference operation/window")
  print("PASS: reference source family case completed")
  }catch{await cleanup();fputs("FAIL reference source family: \\(error)\\n",stderr);exit(1)}
 }
}
'''
if not main.is_file() or main.read_text()!=text:main.write_text(text)
receiver=build_receiver(root,sources+[main],inputs)
with tempfile.TemporaryDirectory(prefix='tg-reference-source-') as temporary:
    folder=Path(temporary)
    env={key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
    env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    env.pop('TURTLEGIT_REFERENCE_SOURCE_CAPTURE',None)
    for case in args.only or cases:
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            context=folder/(case+str(index));context.mkdir()
            for name in ['fixture','home','preferences','temporary','xdg']:(context/name).mkdir(mode=0o700)
            fixture=context/'fixture';config=context/'global.config';config.write_text('')
            active=dict(env,HOME=str(context/'home'),CFFIXED_USER_HOME=str(context/'preferences'),TMPDIR=str(context/'temporary')+'/',XDG_CONFIG_HOME=str(context/'xdg'),GIT_CONFIG_GLOBAL=str(config))
            if args.captures and case=='source' and index==0:active['TURTLEGIT_REFERENCE_SOURCE_CAPTURE']=str(args.captures.absolute())
            print('Checking reference '+case+' with '+str(git),flush=True)
            approved={str(git.resolve())}
            resolved=subprocess.run(['/usr/bin/xcrun','--find','git'],capture_output=True,text=True,timeout=10)
            if resolved.returncode==0:approved.add(str(Path(resolved.stdout.strip()).resolve()))
            passed=False;retained=False
            def retain(error=None):
                target=root/'build/qa/native-reference-source-failures';target.mkdir(parents=True,exist_ok=True)
                evidence=Path(tempfile.mkdtemp(prefix=case+'-'+str(index)+'-',dir=target))
                if error is not None:
                    for name in ['stdout','stderr']:
                        output=getattr(error,name,None)
                        if output is not None:
                            if isinstance(output,bytes):output=output.decode('utf-8',errors='replace')
                            path=context/(name+'.log')
                            if not path.exists():path.write_text(output)
                shutil.copytree(context,evidence,dirs_exist_ok=True,symlinks=True)
                print('Retained private reference source failure: '+str(evidence),flush=True)
            try:
                result=run_receiver([str(receiver),str(fixture),str(git.absolute()),case],cwd=root,env=active,capture_output=True,text=True,timeout=300,timeout_sample=context/'timeout.sample.txt')
                (context/'stdout.log').write_text(result.stdout);(context/'stderr.log').write_text(result.stderr)
                print(result.stdout,end='');print(result.stderr,end='')
                passed=result.returncode==0 and 'PASS: reference source family case completed' in result.stdout
                result.check_returncode()
                if not passed:raise RuntimeError('Receiver exited before final assertions: '+case)
            except BaseException as error:
                retain(error);retained=True;raise
            finally:
                try:
                    if retire_owned_helpers(context,approved) and passed:raise RuntimeError('Successful reference case left an owned helper running: '+case)
                except BaseException:
                    if not retained:retain()
                    raise
