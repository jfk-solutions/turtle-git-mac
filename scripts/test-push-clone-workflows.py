#!/usr/bin/env python3
"""Grouped Push/Clone native workflows using one cached Debug receiver."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
from native_receiver import build_receiver, run_receiver

CASES = {
 'push-progress':('push-progress-native-2026-10-08.swift','PushProgressVerification.main()'),
 'push-stream':('push-stream-native-2026-10-08.swift','PushStreamVerification.main()'),
 'push-cancellation':('push-cancellation-native-2026-10-08.swift','PushCancellationVerification.main()'),
 'push-results':('push-result-refresh-native-2026-10-08.swift','PushResultRefreshVerification.main()'),
 'push-receipts':('push-phase-receipt-native-2026-11-07.swift','PushPhaseReceiptVerification.verify()'),
 'preparation':('transport-preparation-native-2026-10-14.swift','TransportPreparationVerification.verify()'),
 'presentation':('transport-presentation-native-2026-10-15.swift','TransportPresentationVerification.main()'),
 'clone-completion':('clone-completion-native-2026-10-16.swift','CloneCompletionVerification.verify()'),
 'clone-results':('clone-results-family-native-2026-10-19.swift','CloneResultsFamilyVerification.verify()'),
 'clone-progress':('clone-progress-native-2026-10-08.swift','CloneProgressVerification.main()'),
 'clone-stream':('clone-stream-native-2026-10-08.swift','CloneStreamVerification.main()'),
 'clone-ownership':('repository-creation-owned-native-2026-10-14.swift','RepositoryCreationOwnedVerification.verify()'),
 'clone-source-ownership':('clone-create-source-native-2026-10-21.swift','cloneSourceOwnership()'),
 'clone-filter':('clone-checkout-filter-native-2026-10-19.swift','CloneCheckoutFilterVerification.verify()'),
}

def retire_owned_helpers(context, approved):
    """Require an exact Git/editor image or authored shell wrapper and private resource."""
    def owned():
        listing = subprocess.run(['/usr/sbin/lsof', '-t', '+D', str(context)], capture_output=True, text=True, timeout=10)
        if listing.returncode not in (0, 1):
            raise RuntimeError('Cannot inspect private Push/Clone family process ownership')
        found = []
        for item in set(listing.stdout.split()):
            pid = int(item)
            image = subprocess.run(['/usr/sbin/lsof', '-a', '-p', str(pid), '-d', 'txt', '-Fn'], capture_output=True, text=True, timeout=5)
            paths = {str(Path(row[1:]).resolve()) for row in image.stdout.splitlines() if row.startswith('n')}
            if paths.intersection(approved):
                found.append(pid)
                continue
            if paths.intersection({str(Path('/bin/sh').resolve()), '/bin/bash'}):
                command = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True, timeout=5).stdout.strip()
                # Every named script is authored inside this exact private tree.
                wrappers = [path for path in context.rglob('*') if path.is_file() and path.name in {
                    'slow-git', 'record-git', 'held-git', 'counting-git', 'warning-git', 'gate-git', 'smudge', 'record-lfs', 'held-clone', 'push-phase-git', 'post-push-held.sh'}]
                if any(command == '/bin/sh '+str(path) or command.startswith('/bin/sh '+str(path)+' ') for path in wrappers):
                    found.append(pid)
        return found
    needed = bool(owned())
    for number in [signal.SIGTERM, signal.SIGKILL]:
        for pid in owned():
            if pid not in owned():
                continue
            try:
                os.killpg(pid, number) if os.getpgid(pid) == pid else os.kill(pid, number)
            except ProcessLookupError:
                pass
        deadline = time.monotonic()+3
        while time.monotonic() < deadline:
            if not owned():
                return needed
            time.sleep(.03)
    raise RuntimeError('Owned Push/Clone family Git/editor process survived cleanup')


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--only',choices=CASES,action='append')
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
cache=root/'build/qa/push-clone-native-sources';cache.mkdir(parents=True,exist_ok=True)
def write(path,text):
    if not path.is_file() or path.read_text()!=text:path.write_text(text)
fixtures=[]
for filename in dict.fromkeys(filename for filename,_ in CASES.values()):
    source=cache/filename;write(source,(root/'docs/qa'/filename).read_text().replace('@main ','',1));fixtures.append(source)
main=cache/'PushCloneMain.swift'
cases=''.join('case "'+case+'":try await '+call+';\n' for case,(_,call) in CASES.items())
main_source='import AppKit\nimport ObjectiveC\nimport TurtleGitCore\nprivate extension NSWindow {\n @objc func pushCloneBatchFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect{rect}\n @objc func pushCloneBatchOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));pushCloneBatchOrder(place,relativeTo:number)}\n}\n@main enum PushCloneMain {\n struct Failure:Error,CustomStringConvertible{let description:String}\n @MainActor static func cloneSourceOwnership()async throws {\n  let context=CloneCreateSourceVerification.Context();var failure:Error?\n  do{try await CloneCreateSourceVerification.ownership(context)}catch{failure=error}\n  await context.cleanup()\n  guard context.drained()else{throw Failure(description:"Clone source ownership failed to drain: "+String(describing:failure))}\n  if let failure{throw failure}\n }\n @MainActor static func main()async throws {\n  if let status=RebaseEditor.handle(arguments:CommandLine.arguments,environment:ProcessInfo.processInfo.environment){exit(status)}\n  NSApp.setActivationPolicy(.prohibited)\n  let order=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.pushCloneBatchOrder(_:relativeTo:)))!\n  let frame=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:)))!,offscreen=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.pushCloneBatchFrame(_:to:)))!\n  method_exchangeImplementations(order,hidden);method_exchangeImplementations(frame,offscreen)\n  defer{method_exchangeImplementations(frame,offscreen);method_exchangeImplementations(order,hidden)}\n  let which=ProcessInfo.processInfo.environment["TURTLEGIT_PUSH_CLONE_CASE"]!\n  var failure:Error?\n  do{switch which{__CASES__ default:throw Failure(description:"Unknown Push/Clone case")}}catch{failure=error}\n  for window in NSApp.windows{if let parent=window.sheetParent{parent.endSheet(window,returnCode:.abort)};window.makeFirstResponder(nil);window.endEditing(for:nil);window.orderOut(nil);window.close()}\n  for _ in 0..<3000 {\n   let transportDrained=PushWindowModel.activePreparationReads==0 && PushWindowModel.activePushWorkflows==0 && FetchWindowModel.activePreparationReads==0 && LocalGitCommandProgress.activeOperations==0 && ClientHookSession.activeOperations==0 && ClientHookSession.activeQuestionReleases==0 && ClientHookProcessPool.shared.activeScripts==0\n   let cloneDrained=CloneWindowModel.activeOperations==0 && CloneProgressWindowModel.activeOperations==0 && CloneWindowController.activeChildReleases==0 && CloneProgressWindowController.activeReleases==0 && CreateRepositoryWindowModel.activeOperations==0 && CreateRepositoryWindowController.activeReleases==0 && BareRepositoryResultSetup.activeOperations==0\n   if transportDrained && cloneDrained && FinderFilesystemWorkflowRelease.activeRetirements==0 && NSApp.windows.allSatisfy({!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}) {if let failure{throw failure};print("PASS Push/Clone "+which);return}\n   try await Task.sleep(nanoseconds:10_000_000)\n  }\n  let windows=NSApp.windows.map{window in "class=\\(String(describing:type(of:window))) title=\\(window.title) visible=\\(window.isVisible) parent=\\(window.sheetParent?.title ?? "nil") sheet=\\(window.attachedSheet?.title ?? "nil")"}.joined(separator:"\\n")\n  let counters="pushReads=\\(PushWindowModel.activePreparationReads) pushWorkers=\\(PushWindowModel.activePushWorkflows) fetchReads=\\(FetchWindowModel.activePreparationReads) cloneForm=\\(CloneWindowModel.activeOperations) cloneWorkers=\\(CloneProgressWindowModel.activeOperations) cloneReleases=\\(CloneProgressWindowController.activeReleases) localGit=\\(LocalGitCommandProgress.activeOperations) hookWorkers=\\(ClientHookSession.activeOperations) hookQuestions=\\(ClientHookSession.activeQuestionReleases) hookScripts=\\(ClientHookProcessPool.shared.activeScripts) retirements=\\(FinderFilesystemWorkflowRelease.activeRetirements)"\n  throw Failure(description:"Owned Push/Clone workers/windows did not drain; "+counters+"\\n"+windows+"\\ninitialfailure="+String(describing:failure))\n }\n}\n'
write(main,main_source.replace('__CASES__',cases))
receiver=build_receiver(root,fixtures+[main],cache)
results=[];failures=[]
for case in args.only or list(CASES):
    for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
        with tempfile.TemporaryDirectory(prefix='turtlegit-push-clone-'+case+'-') as temporary:
            context=Path(temporary).resolve()
            env={key:value for key,value in os.environ.items() if not key.startswith('GIT_') and not (key.startswith('TURTLEGIT_') and 'CAPTURE' in key)}
            for name,key in [('home','HOME'),('preferences','CFFIXED_USER_HOME'),('xdg','XDG_CONFIG_HOME'),('tmp','TMPDIR')]:
                directory=context/name;directory.mkdir(mode=0o700);env[key]=str(directory)+('/' if key=='TMPDIR' else '')
            if case=='clone-filter':env['PATH']=str(root/'build/git-runtime/Git/bin')+os.pathsep+env.get('PATH','/usr/bin:/bin')
            fixture=context/'repository';fixture.mkdir(mode=0o700)
            config=context/'global.config';config.write_text('')
            editor=root/'build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac'
            env.update(GIT_CONFIG_GLOBAL=str(config),TURTLEGIT_CLONE_FILTER_MARKER='private-clone-context',GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),TURTLEGIT_REBASE_EDITOR=str(editor),TURTLEGIT_PUSH_CLONE_CASE=case)
            approved={str(git.resolve()),str(receiver.resolve()),str(editor.resolve()),str(Path('/usr/bin/ssh-agent').resolve()),str(Path('/usr/bin/ssh-add').resolve()),str(Path('/bin/sleep').resolve()),str((root/'build/libgit2-runtime/LibGit2/bin/turtlegit-libgit2').resolve()),str((root/'build/git-runtime/Git/bin/git-lfs').resolve())}
            resolved=subprocess.run(['/usr/bin/xcrun','--find','git'],capture_output=True,text=True)
            if resolved.returncode==0:approved.add(str(Path(resolved.stdout.strip()).resolve()))
            print('Checking Push/Clone '+case+' with '+str(git),flush=True)
            passed=False
            try:
                result=run_receiver([str(receiver),str(fixture),str(git.absolute()),str((root/'build/libgit2-runtime/LibGit2/bin/turtlegit-libgit2').absolute())],cwd=root,env=env,capture_output=True,text=True,timeout=300,timeout_sample=context/'timeout.sample.txt')
                print(result.stdout,end='');print(result.stderr,end='')
                passed=result.returncode==0 and 'PASS Push/Clone '+case in result.stdout
                results.append(dict(case=case,git=str(git.absolute()),returncode=result.returncode,passed=passed))
                result.check_returncode()
                if not passed:raise RuntimeError('Receiver exited before final assertions: '+case)
            except Exception as error:
                failures.append(dict(case=case,git=str(git.absolute()),error=str(error)))
                print('FAILED Push/Clone '+case+': '+str(error),flush=True)
            finally:
                sample=context/'timeout.sample.txt'
                if sample.is_file():shutil.copyfile(sample,root/('build/qa/push-clone-'+case+'-'+str(index)+'.sample.txt'))
                if retire_owned_helpers(context,approved):
                    failures.append(dict(case=case,git=str(git.absolute()),error='Owned helper required cleanup'))
                    if passed:results[-1].update(passed=False,helper_cleanup_needed=True)
                (root/'build/qa/push-clone-native-results.json').write_text(json.dumps(dict(results=results,failures=failures),indent=2)+'\n')
if failures:raise SystemExit('Push/Clone failures: '+json.dumps(failures))
