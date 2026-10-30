#!/usr/bin/env python3
"""Grouped native Bisect source controls, revisions, operations and owned lifetime."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--git',type=Path,action='append')
p.add_argument('--only',choices=['controls','picker','ownership','recovery'],action='append')
p.add_argument('--captures',type=Path)
a=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-bisect-source-') as temporary:
    directory=Path(temporary);selected=a.only or ['controls','picker','ownership'];receivers={}
    if any(case!='recovery' for case in selected):
        receiver=build_receiver(root,[root/'docs/qa/bisect-source-controls-native-2026-10-21.swift'],directory)
        receivers.update({case:receiver for case in selected if case!='recovery'})
    if 'recovery' in selected:
        original=root/'docs/qa/cherry-pick-native-receiver-2026-10-06.swift'
        text=original.read_text()
        assert text.count('@main struct Receiver')==1,'Original replay receiver entry point changed'
        copied=directory/'RetainedBisectRecovery.swift';copied.write_text(text.replace('@main struct Receiver','struct Receiver',1))
        main=directory/'BisectRecoveryMain.swift'
        main.write_text('''import AppKit
import ObjectiveC
private extension NSWindow {
 @objc func bisectRecoveryOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {alphaValue=0;setFrameOrigin(.init(x:-18000,y:-18000));bisectRecoveryOrder(mode,relativeTo:number)}
}
@main struct BisectRecoveryMain {
 @MainActor static func main()async throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.bisectRecoveryOrder(_:relativeTo:)))!
  method_exchangeImplementations(original,hidden)
  defer {method_exchangeImplementations(original,hidden);for window in NSApp.windows {window.close()}}
  try await verifyNativeBisect(executable:URL(fileURLWithPath:CommandLine.arguments[2]))
  print("PASS: Bisect source recovery")
 }
}
''')
        receivers['recovery']=build_receiver(root,[copied,main],directory)
    env={key:value for key,value in os.environ.items() if not key.startswith('GIT_')};env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for key in ['GIT_CONFIG_PARAMETERS','GIT_AUTHOR_NAME','GIT_AUTHOR_EMAIL','GIT_AUTHOR_DATE','GIT_COMMITTER_NAME','GIT_COMMITTER_EMAIL','GIT_COMMITTER_DATE']:env.pop(key,None)
    if a.captures:a.captures.mkdir(parents=True,exist_ok=True);env['TURTLEGIT_BISECT_SOURCE_CAPTURES']=str(a.captures.absolute())
    for case in selected:
        for index,git in enumerate(a.git or [Path('/usr/bin/git')]):
            directory_case=directory/(case+str(index));directory_case.mkdir()
            private=directory/(case+str(index)+'-environment');private.mkdir(mode=0o700)
            home=private/'home';home.mkdir(mode=0o700);(home/'Library/Preferences').mkdir(parents=True,mode=0o700)
            tmp=private/'temporary';tmp.mkdir(mode=0o700);xdg=private/'xdg';xdg.mkdir(mode=0o700)
            active=dict(env,HOME=str(home),CFFIXED_USER_HOME=str(home),TMPDIR=str(tmp)+'/',XDG_CONFIG_HOME=str(xdg))
            print('Checking Bisect '+case+' with '+str(git),flush=True)
            result=run_receiver([str(receivers[case]),str(directory_case),str(git.absolute()),case],cwd=root,env=active,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: Bisect source '+case not in result.stdout:raise SystemExit('Receiver exited before final assertions: '+case)
