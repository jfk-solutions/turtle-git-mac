#!/usr/bin/env python3
"""Grouped source regex list/editor and retained actual comparison filtering."""
import argparse,ast,json,os,shutil,signal,subprocess,tempfile,time
from pathlib import Path
from native_receiver import build_receiver,run_receiver
cases={'source':'MergeRegexSourceVerification','comparison':'MergeRegexNativeVerification','files':'MergeRegexFilesVerification'}
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--only',choices=cases,action='append');p.add_argument('--captures',type=Path);args=p.parse_args();root=Path(__file__).resolve().parent.parent
cleanup_tree=ast.parse((root/'scripts/test-log-file-drags.py').read_text())
cleanup=next(item for item in cleanup_tree.body if isinstance(item,ast.FunctionDef) and item.name=='retire_owned_helpers')
namespace=dict(os=os,signal=signal,time=time,subprocess=subprocess,Path=Path)
exec(compile(ast.Module(body=[cleanup],type_ignores=[]),'<owned regex source helpers>','exec'),namespace)
retire_owned_helpers=namespace['retire_owned_helpers']
with tempfile.TemporaryDirectory(prefix='tg-regex-source-') as temporary:
    folder=Path(temporary);sources=[]
    for name in ['merge-regex-source-native-2026-10-17.swift','merge-regex-native-2026-10-12.swift','merge-regex-files-native-2026-10-17.swift']:
        path=folder/name;path.write_text((root/'docs/qa'/name).read_text().replace('@main ', '',1));sources.append(path)
    main=folder/'RegexSourceMain.swift'
    text=r'''import AppKit
import ObjectiveC
private extension NSWindow {
 @objc func regexSourceOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;setFrameOrigin(.init(x:-28000,y:-28000));regexSourceOrder(mode,relativeTo:number)
 }
 @objc func regexSourceConstrain(_ frame:NSRect,to screen:NSScreen?)->NSRect {frame}
}
@main struct RegexSourceMain {
 struct Failure:Error,CustomStringConvertible {let description:String}
 @MainActor static func drain()async->Bool {
  let comparisons=NSApp.windows.compactMap{$0.delegate as? FileComparisonWindowController}
  for window in NSApp.windows {if let parent=window.sheetParent {parent.endSheet(window,returnCode:.abort)};window.close()}
  for _ in 0..<3000 {
   if MergeRegexFilterListController.activeEditors==0,MergeRegexOperations.activeRequests==0,
      FileComparisonWindowModel.activeProjectionChoices==0,FileComparisonWindowModel.activePaneExports==0,
      comparisons.allSatisfy({!$0.mergeToolHasPendingWork}),
      NSApp.windows.allSatisfy({!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}) {return true}
   try? await Task.sleep(nanoseconds:10_000_000)
  }
  return false
 }
 @MainActor static func main()async throws {
  NSApp.setActivationPolicy(.prohibited)
  let hidden=ProcessInfo.processInfo.environment["TURTLEGIT_REGEX_SOURCE_CAPTURE"]==nil && ProcessInfo.processInfo.environment["TURTLEGIT_REGEX_FILES_CAPTURE"]==nil
  if hidden {
   method_exchangeImplementations(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,class_getInstanceMethod(NSWindow.self,#selector(NSWindow.regexSourceOrder(_:relativeTo:)))!)
   method_exchangeImplementations(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:)))!,class_getInstanceMethod(NSWindow.self,#selector(NSWindow.regexSourceConstrain(_:to:)))!)
  }
  defer {if hidden {
   method_exchangeImplementations(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,class_getInstanceMethod(NSWindow.self,#selector(NSWindow.regexSourceOrder(_:relativeTo:)))!)
   method_exchangeImplementations(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:)))!,class_getInstanceMethod(NSWindow.self,#selector(NSWindow.regexSourceConstrain(_:to:)))!)
  }}
  let parser=URL(fileURLWithPath:CommandLine.arguments[2]);var failure:Error?
  do {switch CommandLine.arguments[1] {
'''
    text+=''.join('case "'+case+'": try await '+kind+'.verify(parser:parser)\n' for case,kind in cases.items())
    text+=r'''default:throw Failure(description:"Unknown regex case")
  }} catch {failure=error}
  guard await drain() else {throw Failure(description:"Owned regex readers/windows did not drain; original failure: \(String(describing:failure))")}
  if let failure {throw failure}
  print("PASS: Regex source family case completed")
 }
}
'''
    main.write_text(text)
    receiver=build_receiver(root,sources+[main],folder)
    parser=root/'build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/IssueRegex/issue-regex'
    results=[]
    for case in args.only or cases:
        context=folder/case;context.mkdir()
        for name in ['preferences','temporary','xdg']:(context/name).mkdir(mode=0o700)
        config=context/'global.config';config.write_text('')
        active={key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
        active.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=str(config),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',
                      CFFIXED_USER_HOME=str(context/'preferences'),TMPDIR=str(context/'temporary')+'/',XDG_CONFIG_HOME=str(context/'xdg'))
        active.pop('TURTLEGIT_REGEX_SOURCE_CAPTURE',None);active.pop('TURTLEGIT_REGEX_FILES_CAPTURE',None)
        if args.captures and case=='source':active['TURTLEGIT_REGEX_SOURCE_CAPTURE']=str(args.captures.absolute())
        if args.captures and case=='files':active['TURTLEGIT_REGEX_FILES_CAPTURE']=str(args.captures.absolute())
        passed=False;retained=False
        def retain():
            target=root/'build/qa/native-regex-source-failures';target.mkdir(parents=True,exist_ok=True)
            evidence=Path(tempfile.mkdtemp(prefix=case+'-',dir=target))
            shutil.copytree(context,evidence,dirs_exist_ok=True,symlinks=True)
            print('Retained private regex source evidence: '+str(evidence),flush=True)
        print('Checking regex '+case,flush=True)
        try:
            result=run_receiver([str(receiver),case,str(parser)],cwd=root,env=active,capture_output=True,text=True,timeout=300,timeout_sample=context/'timeout.sample.txt')
            (context/'receiver.stdout.log').write_text(result.stdout);(context/'receiver.stderr.log').write_text(result.stderr)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: Regex source family case completed' not in result.stdout:raise RuntimeError('Receiver exited before final assertions/cleanup: '+case)
            passed=True;results.append(dict(case=case,exit_code=result.returncode,passed=True))
            (root/'build/qa/regex-source-native-results.json').write_text(json.dumps(results,indent=2)+'\n')
        except BaseException:
            retain();retained=True;raise
        finally:
            try:
                needed=retire_owned_helpers(context,{str(parser.resolve())})
                if passed and needed:raise RuntimeError('Successful regex receiver left owned helpers')
            except BaseException:
                if not retained:retain()
                raise
