#!/usr/bin/env python3
"""Grouped Stash/Submodule native workflows using one cached Debug receiver."""
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
    'stash': ('stash-operation-native-2026-10-18.swift', 'StashOperationVerification.verify()'),
    'stash-save': ('stash-save-progress-native-2026-10-08.swift', 'StashSaveProgressVerification.main()'),
    'stash-restore': ('stash-restore-native-2026-10-08.swift', 'StashRestoreVerification.verify()'),
    'add-recovery': ('submodule-add-recovery-native-2026-10-18.swift', 'SubmoduleAddRecoveryVerification.verify()'),
    'update-recovery': ('submodule-update-recovery-native-2026-10-18.swift', 'SubmoduleUpdateRecoveryVerification.verify()'),
    'update-progress': ('submodule-update-progress-native-2026-10-09.swift', 'SubmoduleUpdateProgressReceiver.run()'),
    'sync': ('submodule-sync-native-2026-10-09.swift', 'SubmoduleSyncReceiver.run()'),
    'handoffs': ('submodule-handoffs-native-2026-10-14.swift', 'SubmoduleHandoffsVerification.verify()'),
    'integration-entry': ('integration-commands-native-2026-10-18.swift', 'PrimaryCommandsVerification.verifyIntegration()'),
    'submodule-entry': ('submodule-commands-native-2026-10-18.swift', 'PrimaryCommandsVerification.verifySubmoduleCommands()'),
    'stash-mutation-save': ('stash-mutation-recovery-native-2026-11-07.swift', 'StashMutationRecoveryVerification.verifySave()'),
    'stash-replay-identity': ('stash-mutation-recovery-native-2026-11-07.swift', 'StashMutationRecoveryVerification.verifyReplay()'),
    'stash-mutation-restore': ('stash-mutation-recovery-native-2026-11-07.swift', 'StashMutationRecoveryVerification.verifyRestore()'),
    'source': ('submodule-source-native-2026-10-17.swift', 'SubmoduleSourceVerification.verify()'),
    'inputs': ('submodule-add-inputs-native-2026-10-17.swift', 'SubmoduleAddInputsVerification.verify()'),
    'diff-entry': ('submodule-diff-entry-native-2026-10-18.swift', 'SubmoduleDiffEntryVerification.verify()'),
    'review-actions': ('submodule-review-family-native-2026-10-21.swift', 'review("actions")'),
    'review-diff-ownership': ('submodule-review-family-native-2026-10-21.swift', 'review("diff-ownership")'),
    'review-routing': ('submodule-review-family-native-2026-10-21.swift', 'review("routing")'),
    'review-conflict-ownership': ('submodule-review-family-native-2026-10-21.swift', 'review("conflict-ownership")'),
}

def retire_owned_helpers(context, approved):
    """Require an exact Git/editor image or authored shell wrapper and private resource."""
    def owned():
        listing = subprocess.run(['/usr/sbin/lsof', '-t', '+D', str(context)], capture_output=True, text=True, timeout=10)
        if listing.returncode not in (0, 1):
            raise RuntimeError('Cannot inspect private Stash/Submodule family process ownership')
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
                    'git-add-recovery', 'git-recovery-wrapper', 'paused-git', 'held-git', 'stash-lookup-git', 'replay-stash-git', 'local-git'}]
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
    raise RuntimeError('Owned Stash/Submodule family Git/editor process survived cleanup')


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--only',choices=CASES,action='append')
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
cache=root/'build/qa/stash-submodule-native-sources';cache.mkdir(parents=True,exist_ok=True)
def write(path,text):
    if not path.is_file() or path.read_text()!=text:path.write_text(text)
fixtures=[]
for filename in dict.fromkeys(filename for filename,_ in CASES.values()):
    source=cache/filename;write(source,(root/'docs/qa'/filename).read_text().replace('@main ','',1));fixtures.append(source)
primary=(root/'docs/qa/primary-commands-native-2026-10-18.swift').read_text()
helper=cache/'PrimaryCommandsAssertions.swift'
assertion_prefix=primary[:primary.index('    @MainActor static func verifyNetwork()')].replace('@main ','',1)
single_assertion=next(line for line in primary.splitlines() if line.startswith('    static func requireOne'))
write(helper,assertion_prefix+single_assertion+'\n}\n');fixtures.append(helper)
main=cache/'StashSubmoduleMain.swift'
cases=''.join('case "'+case+'":try await '+call+';\n' for case,(_,call) in CASES.items())
main_source='import AppKit\nimport ObjectiveC\nimport TurtleGitCore\nprivate extension NSWindow {\n @objc func stashBatchFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect{rect}\n @objc func stashBatchOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));stashBatchOrder(place,relativeTo:number)}\n}\n@main enum StashSubmoduleMain {\n struct Failure:Error,CustomStringConvertible{let description:String}\n @MainActor static func review(_ which:String)async throws {\n  let context=SubmoduleReviewVerification.Context();var failure:Error?\n  do{switch which{case "actions":try await SubmoduleReviewVerification.actions(context);case "diff-ownership":try await SubmoduleReviewVerification.diffOwnership(context);case "routing":try await SubmoduleReviewVerification.routing(context);default:try await SubmoduleReviewVerification.conflictOwnership(context)}}catch{failure=error}\n  await context.cleanup()\n  guard SubmoduleReviewVerification.drained(context.owners)else{throw Failure(description:"Review failed to drain: "+String(describing:failure))}\n  if let failure{throw failure}\n }\n @MainActor static func main()async throws {\n  if let status=RebaseEditor.handle(arguments:CommandLine.arguments,environment:ProcessInfo.processInfo.environment){exit(status)}\n  NSApp.setActivationPolicy(.prohibited)\n  let order=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.stashBatchOrder(_:relativeTo:)))!\n  let frame=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:)))!,offscreen=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.stashBatchFrame(_:to:)))!\n  method_exchangeImplementations(order,hidden);method_exchangeImplementations(frame,offscreen)\n  defer{method_exchangeImplementations(frame,offscreen);method_exchangeImplementations(order,hidden)}\n  let which=ProcessInfo.processInfo.environment["TURTLEGIT_STASH_SUBMODULE_CASE"]!\n  var failure:Error?\n  do{switch which{__CASES__ default:throw Failure(description:"Unknown Stash/Submodule case")}}catch{failure=error}\n  for window in NSApp.windows{if let parent=window.sheetParent{parent.endSheet(window,returnCode:.abort)};window.makeFirstResponder(nil);window.endEditing(for:nil);window.orderOut(nil);window.close()}\n  for _ in 0..<3000 {\n   let stashDrained=StashWindowModel.activePreparations==0 && StashSaveProgressWindowModel.activeOperations==0 && StashRestoreWindowModel.activeOperations==0 && StashWindowController.activeChildReleases==0 && RebaseWindowModel.activeReplayOperations==0 && RebaseWindowModel.activeStashRestorations==0\n   let submoduleDrained=SubmoduleAddProgressWindowModel.activeOperations==0 && SubmoduleUpdateWindowModel.activeReads==0 && SubmoduleUpdateProgressWindowModel.activeOperations==0 && SubmoduleSyncWindowModel.activeOperations==0 && SubmoduleUpdateProgressWindowController.activeChildReleases==0\n   if stashDrained && submoduleDrained && LocalGitCommandProgress.activeOperations==0 && FinderFilesystemWorkflowRelease.activeRetirements==0 && SubmoduleReviewVerification.drained([]) && NSApp.windows.allSatisfy({!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}) {if let failure{throw failure};print("PASS Stash/Submodule "+which);return}\n   try await Task.sleep(nanoseconds:10_000_000)\n  }\n  throw Failure(description:"Owned Stash/Submodule workers/windows did not drain; initialfailure="+String(describing:failure))\n }\n}\n'
write(main,main_source.replace('__CASES__',cases))
receiver=build_receiver(root,fixtures+[main],cache)
results=[];failures=[]
for case in args.only or list(CASES):
    for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
        with tempfile.TemporaryDirectory(prefix='turtlegit-stash-submodule-'+case+'-') as temporary:
            context=Path(temporary).resolve()
            env={key:value for key,value in os.environ.items() if not key.startswith('GIT_') and not (key.startswith('TURTLEGIT_') and 'CAPTURE' in key)}
            for name,key in [('home','HOME'),('preferences','CFFIXED_USER_HOME'),('xdg','XDG_CONFIG_HOME'),('tmp','TMPDIR')]:
                directory=context/name;directory.mkdir(mode=0o700);env[key]=str(directory)+('/' if key=='TMPDIR' else '')
            fixture=context/'repository';fixture.mkdir(mode=0o700)
            editor=root/'build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac'
            env.update(GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),TURTLEGIT_REBASE_EDITOR=str(editor),TURTLEGIT_STASH_SUBMODULE_CASE=case)
            approved={str(git.resolve()),str(receiver.resolve()),str(editor.resolve()),str(Path('/usr/bin/ssh-agent').resolve()),str(Path('/usr/bin/ssh-add').resolve()),str(Path('/bin/sleep').resolve())}
            resolved=subprocess.run(['/usr/bin/xcrun','--find','git'],capture_output=True,text=True)
            if resolved.returncode==0:approved.add(str(Path(resolved.stdout.strip()).resolve()))
            print('Checking Stash/Submodule '+case+' with '+str(git),flush=True)
            passed=False
            try:
                result=run_receiver([str(receiver),str(fixture),str(git.absolute()),case],cwd=root,env=env,capture_output=True,text=True,timeout=300,timeout_sample=context/'timeout.sample.txt')
                print(result.stdout,end='');print(result.stderr,end='')
                passed=result.returncode==0 and 'PASS Stash/Submodule '+case in result.stdout
                results.append(dict(case=case,git=str(git.absolute()),returncode=result.returncode,passed=passed))
                result.check_returncode()
                if not passed:raise RuntimeError('Receiver exited before final assertions: '+case)
            except Exception as error:
                failures.append(dict(case=case,git=str(git.absolute()),error=str(error)))
                print('FAILED Stash/Submodule '+case+': '+str(error),flush=True)
            finally:
                sample=context/'timeout.sample.txt'
                if sample.is_file():shutil.copyfile(sample,root/('build/qa/stash-submodule-'+case+'-'+str(index)+'.sample.txt'))
                if retire_owned_helpers(context,approved):
                    failures.append(dict(case=case,git=str(git.absolute()),error='Owned helper required cleanup'))
                    if passed:results[-1].update(passed=False,helper_cleanup_needed=True)
                (root/'build/qa/stash-submodule-native-results.json').write_text(json.dumps(dict(results=results,failures=failures),indent=2)+'\n')
if failures:raise SystemExit('Stash/Submodule failures: '+json.dumps(failures))
