#!/usr/bin/env python3
"""Grouped source Switch form, retained full pickers and real checkout/progress."""
import argparse,os,shutil,signal,subprocess,tempfile,time
from pathlib import Path
from native_receiver import build_receiver,run_receiver

def retire_owned_helpers(fixture, approved_images):
    """Reap only exact Git images or this fixture's authored slow-switch job.

    CancellableGitProcess starts separate process groups, so receiver teardown
    alone cannot retire a helper left behind by a crashed assertion.
    """
    # Preserve argv spelling as passed to the receiver as well as macOS's
    # canonical /private/var alias; both name this exact authored wrapper.
    wrappers={str(fixture.absolute()/'slow-git'),str(fixture.resolve()/'slow-git')}
    fixture=fixture.resolve()
    shell=str(Path('/bin/sh').resolve())
    sleeper=str(Path('/bin/sleep').resolve())
    def owned():
        listing=subprocess.run(['/usr/sbin/lsof','-t','+D',str(fixture)],capture_output=True,text=True,timeout=10)
        if listing.returncode not in (0,1):raise RuntimeError('Cannot inspect private Switch helper ownership')
        try:
            recorded=[int(value) for value in (fixture/'slow-git.started').read_text().split()]
        except (FileNotFoundError,ValueError):recorded=[]
        result=[]
        for value in set(listing.stdout.split()):
            pid=int(value)
            executable=subprocess.run(['/usr/sbin/lsof','-a','-p',str(pid),'-d','txt','-Fn'],capture_output=True,text=True,timeout=5)
            images={str(Path(line[1:]).resolve()) for line in executable.stdout.splitlines() if line.startswith('n')}
            if images.intersection(approved_images):result.append(pid);continue
            command=subprocess.run(['/bin/ps','-p',str(pid),'-o','command='],capture_output=True,text=True,timeout=5).stdout.strip()
            if shell in images and any(command=='/bin/sh '+wrapper or command.startswith('/bin/sh '+wrapper+' ') for wrapper in wrappers):
                result.append(pid)
            elif sleeper in images and command=='/bin/sleep 30' and len(recorded)==2 and pid==recorded[1]:
                try:
                    if os.getpgid(pid)==recorded[0]:result.append(pid)
                except ProcessLookupError:pass
        return result
    remaining=owned();needed=bool(remaining)
    for number in (signal.SIGTERM,signal.SIGKILL):
        for pid in remaining:
            if pid not in owned():continue
            try:
                group=os.getpgid(pid)
                os.killpg(group,number) if group==pid else os.kill(pid,number)
            except ProcessLookupError:pass
        deadline=time.monotonic()+3
        while time.monotonic()<deadline:
            remaining=owned()
            if not remaining:return needed
            time.sleep(.03)
    raise RuntimeError('Verified private Switch helper survived cleanup: '+str(remaining))

cases={'source':('switch-source-native-2026-10-17.swift','SwitchSourceVerification','verify'),'pickers':('switch-pickers-native-2026-10-09.swift','SwitchPickerVerification','verify'),'progress':('switch-progress-native-2026-10-08.swift','SwitchProgressVerification','main')}
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--git',type=Path,action='append');p.add_argument('--only',choices=cases,action='append');p.add_argument('--captures',type=Path);args=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-switch-source-') as temporary:
    folder=Path(temporary);sources=[];inputs=root/'build/qa/switch-source-inputs';inputs.mkdir(parents=True,exist_ok=True)
    for name,_,_ in cases.values():
        path=inputs/name;text=(root/'docs/qa'/name).read_text().replace('@main ', '',1)
        if not path.exists() or path.read_text()!=text:path.write_text(text)
        sources.append(path)
    main=inputs/'SwitchSourceMain.swift'
    text='''import AppKit
import ObjectiveC
private extension NSWindow {
 @objc func turtleGitSwitchOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;setFrameOrigin(.init(x:-12000,y:-12000));turtleGitSwitchOrder(place,relativeTo:number)
 }
 @objc func turtleGitSwitchConstrain(_ frame:NSRect,to screen:NSScreen?)->NSRect {frame}
}
@main struct SwitchSourceMain {
 @MainActor static func drain()async throws {
  for window in NSApp.windows {if let parent=window.sheetParent {parent.endSheet(window,returnCode:.cancel)};window.close()}
  for _ in 0..<2500 {
   if SwitchWindowModel.activeReads==0 && SwitchProgressWindowModel.activeOperations==0 && SwitchWindowController.activeChildReleases==0 && !NSApp.windows.contains(where:{$0.isVisible || $0.sheetParent != nil || $0.attachedSheet != nil}) {return}
   try await Task.sleep(nanoseconds:10_000_000)
  }
  throw SwitchSourceVerification.Failure(description:"Switch source owned windows/work did not drain")
 }
 @MainActor static func main()async throws {
  NSApp.setActivationPolicy(.prohibited)
  let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
  let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitSwitchOrder(_:relativeTo:)))!
  let constrain=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:)))!
  let offscreen=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitSwitchConstrain(_:to:)))!
  let automated=ProcessInfo.processInfo.environment["TURTLEGIT_SWITCH_SOURCE_CAPTURE"] == nil
  if automated {method_exchangeImplementations(original,hidden);method_exchangeImplementations(constrain,offscreen)}
  defer {if automated {method_exchangeImplementations(original,hidden);method_exchangeImplementations(constrain,offscreen)}}
  do {switch CommandLine.arguments[3] {
'''+''.join('case "'+case+'": try await '+kind+'.'+entry+'()\n' for case,(_,kind,entry) in cases.items())+'''default:fatalError("Unknown Switch case")
  };try await drain()} catch {
   let failure=error
   do {try await drain()} catch {throw SwitchSourceVerification.Failure(description:"\\(failure); cleanup: \\(error)")}
   throw failure
  }
  print("PASS: Switch source family case completed")
 }
}
'''
    if not main.exists() or main.read_text()!=text:main.write_text(text)
    receiver=build_receiver(root,sources+[main],inputs)
    env={key:value for key,value in os.environ.items() if not key.startswith('GIT_')};env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0');env.pop('TURTLEGIT_SWITCH_SOURCE_CAPTURE',None)
    for case in args.only or cases:
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            context=folder/(case+str(index));context.mkdir()
            for name in ['fixture','home','preferences','temporary','xdg']:(context/name).mkdir(mode=0o700)
            fixture=context/'fixture';config=context/'global.config';config.write_text('')
            active=dict(env,HOME=str(context/'home'),CFFIXED_USER_HOME=str(context/'preferences'),TMPDIR=str(context/'temporary')+'/',XDG_CONFIG_HOME=str(context/'xdg'),GIT_CONFIG_GLOBAL=str(config))
            if args.captures and case=='source' and index==0:active['TURTLEGIT_SWITCH_SOURCE_CAPTURE']=str(args.captures.absolute())
            print('Checking Switch '+case+' with '+str(git),flush=True)
            approved={str(git.resolve())}
            resolved=subprocess.run(['/usr/bin/xcrun','--find','git'],capture_output=True,text=True,timeout=10)
            if resolved.returncode==0:approved.add(str(Path(resolved.stdout.strip()).resolve()))
            passed=False;retained=False
            def retain():
                target=root/'build/qa/native-switch-source-failures';target.mkdir(parents=True,exist_ok=True)
                evidence=Path(tempfile.mkdtemp(prefix=case+'-',dir=target));shutil.copytree(context,evidence,dirs_exist_ok=True,symlinks=True)
                print('Retained private Switch source failure: '+str(evidence),flush=True)
            try:
                result=run_receiver([str(receiver),str(fixture),str(git.absolute()),case],cwd=root,env=active,capture_output=True,text=True,timeout=300,timeout_sample=context/'timeout.sample.txt')
                (context/'stdout.log').write_text(result.stdout);(context/'stderr.log').write_text(result.stderr)
                print(result.stdout,end='');print(result.stderr,end='')
                passed=result.returncode==0 and 'PASS: Switch source family case completed' in result.stdout
                result.check_returncode()
                if not passed:raise SystemExit('Receiver exited before final assertions: '+case)
            except BaseException:
                retain();retained=True;raise
            finally:
                try:
                    if retire_owned_helpers(fixture,approved) and passed:
                        raise RuntimeError('Completed Switch '+case+' left an owned Git/helper process running')
                except BaseException:
                    if not retained:retain()
                    raise
