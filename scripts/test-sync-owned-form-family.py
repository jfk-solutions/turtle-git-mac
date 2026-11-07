#!/usr/bin/env python3
"""Captured Sync forms, progress handoffs and history under one cached receiver."""
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

CASES = ['conflict', 'child', 'history', 'pull', 'fetch-merge', 'literal-push', 'literal-pull', 'literal-lifetime', 'dialog']
SOURCES = ['sync-conflict-files-native-2026-10-17.swift', 'sync-child-progress-native-2026-10-17.swift',
           'synchronization-history-native-2026-10-11.swift', 'sync-literal-reference-native-2026-10-24.swift',
           'synchronization-native-2026-10-11.swift', 'synchronization-apply-native-2026-10-11.swift',
           'synchronization-email-native-2026-10-11.swift']


def retire_owned_helpers(context, approved):
    """Require an exact Git/editor image or authored shell wrapper and private resource."""
    def owned():
        listing = subprocess.run(['/usr/sbin/lsof', '-t', '+D', str(context)], capture_output=True, text=True, timeout=10)
        if listing.returncode not in (0, 1):
            raise RuntimeError('Cannot inspect private Sync family process ownership')
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
                    'history-held-git', 'recovery-held-merge', 'metadata-git', 'qa-checkout-git', 'qa-sync-git'}]
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
    raise RuntimeError('Owned Sync family Git/editor process survived cleanup')


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=CASES, action='append')
parser.add_argument('--captures', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
cache = root/'build/qa/sync-owned-form-native-sources'
cache.mkdir(parents=True, exist_ok=True)
fixtures = []
for name in SOURCES:
    text = (root/'docs/qa'/name).read_text().replace('@main ', '', 1)
    if name.startswith('synchronization-history-'):
        text = text.split('@_cdecl("turtlegit_history_main")', 1)[0]
    path = cache/name
    if not path.is_file() or path.read_text() != text:
        path.write_text(text)
    fixtures.append(path)
main = cache/'SyncOwnedFormFamilyMain.swift'
body = r'''import AppKit
import ObjectiveC
import TurtleGitCore
private extension NSWindow {
 @objc func syncOwnedFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect{rect}
 @objc func syncOwnedOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int){
  if ProcessInfo.processInfo.environment["TURTLEGIT_SYNC_FAMILY_CAPTURES"] == nil {alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000))}
  syncOwnedOrder(place,relativeTo:number)
 }
}
@main enum SyncOwnedFormFamilyMain {
 struct Failure:Error,CustomStringConvertible{let description:String}
 @MainActor static func main()async throws {
  if let status=RebaseEditor.handle(arguments:CommandLine.arguments,environment:ProcessInfo.processInfo.environment){exit(status)}
  NSApp.setActivationPolicy(.prohibited)
  let method=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.syncOwnedOrder(_:relativeTo:)))!
  let frame=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:)))!,offscreen=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.syncOwnedFrame(_:to:)))!
  method_exchangeImplementations(method,hidden);method_exchangeImplementations(frame,offscreen)
  defer{method_exchangeImplementations(frame,offscreen);method_exchangeImplementations(method,hidden)}
  let suite="TurtleGit.SyncOwnedFamily."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
  prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"ConfirmKillProcess");prefs.set(0,forKey:"AutoCloseGitProgress")
  DialogGeometry.install(preferences:prefs)
  defer{DialogGeometry.install(preferences:.standard);prefs.removePersistentDomain(forName:suite)}
  let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true),which=ProcessInfo.processInfo.environment["TURTLEGIT_SYNC_OWNED_FAMILY_CASE"]!
  var failure:Error?
  do {
   try await ComparisonToolInvocation.$alternate.withValue(false) {
    switch which {
    case "conflict":try await SyncConflictFilesVerification.main()
    case "child":try await SyncChildProgressVerification.main()
    case "history":try await SynchronizationHistoryVerification.main()
    case "pull":try await SynchronizationVerification.verifyPull(root:root,preferences:prefs)
    case "fetch-merge":try await SynchronizationVerification.verifyFetchAndRebase(root:root,preferences:prefs)
    case "literal-push","literal-pull","literal-lifetime":try await SyncLiteralReferenceVerification.main()
    case "dialog":try await SynchronizationVerification.main()
    default:throw Failure(description:"Unknown Sync family case")
    }
   }
  }catch{failure=error}
  for window in NSApp.windows {
   if let parent=window.sheetParent{parent.endSheet(window,returnCode:.abort)}
   window.makeFirstResponder(nil);window.endEditing(for:nil);window.orderOut(nil);window.close()
  }
  for _ in 0..<3000 {
   let drained=SynchronizationProgressModel.activeOperations==0 && SynchronizationWindowModel.activeInlineOperations==0 && SynchronizationWindowController.activeInlineReleases==0 && FinderFilesystemWorkflowRelease.activeRetirements==0 && StatusWindowModel.activeOperations==0 && CommitWindowModel.activeReloads==0 && FileListComparisonSession.activeOperations==0
   if drained && NSApp.windows.allSatisfy({!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}) {
    if let failure{throw failure};print("PASS Sync owned family "+which);return
   }
   try await Task.sleep(nanoseconds:10_000_000)
  }
  throw Failure(description:"Sync family did not drain owned workers/windows; initial failure="+String(describing:failure))
 }
}
'''
if not main.is_file() or main.read_text() != body:
    main.write_text(body)
receiver = build_receiver(root, fixtures+[main], cache)
results = []
failures = []
for case in args.only or CASES[:-1]:
    for index, git in enumerate(args.git or [Path('/usr/bin/git'), root/'build/git-runtime/Git/bin/git']):
        with tempfile.TemporaryDirectory(prefix='turtlegit-sync-owned-'+case+'-') as temporary:
            context = Path(temporary).resolve()
            env = {key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
            for name,key in [('home','HOME'), ('preferences','CFFIXED_USER_HOME'), ('xdg','XDG_CONFIG_HOME'), ('tmp','TMPDIR')]:
                path = context/name; path.mkdir(mode=0o700); env[key] = str(path)+('/' if key == 'TMPDIR' else '')
            fixture = context/'repository'; fixture.mkdir(mode=0o700)
            env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                       DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), TURTLEGIT_SYNC_OWNED_FAMILY_CASE=case)
            if args.captures and index == 0:
                env['TURTLEGIT_SYNC_FAMILY_CAPTURES'] = str(args.captures.absolute())
                if case == 'conflict': env['TURTLEGIT_SYNC_CONFLICT_CAPTURE'] = str(args.captures.absolute())
                if case == 'child': env['TURTLEGIT_SYNC_CHILD_CAPTURE'] = str(args.captures.absolute())
            else:
                for key in ['TURTLEGIT_SYNC_FAMILY_CAPTURES', 'TURTLEGIT_SYNC_CONFLICT_CAPTURE', 'TURTLEGIT_SYNC_CHILD_CAPTURE']:
                    env.pop(key, None)
            mode = case.removeprefix('literal-')
            command = [str(receiver), str(fixture), str(git.absolute()), mode]
            approved = {str(git.resolve()),str(receiver.resolve())}
            for path in [root/'.build/debug/TurtleGitMac', root/'build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac']:
                if path.is_file(): approved.add(str(path.resolve()))
            resolved = subprocess.run(['/usr/bin/xcrun','--find','git'],capture_output=True,text=True)
            if resolved.returncode == 0: approved.add(str(Path(resolved.stdout.strip()).resolve()))
            print('Checking Sync owned family '+case+' with '+str(git),flush=True)
            passed = False
            try:
                result = run_receiver(command, cwd=root, env=env, capture_output=True, text=True,
                                      timeout=1200 if case == 'dialog' else 300,
                                      timeout_sample=context/'timeout.sample.txt')
                print(result.stdout,end='');print(result.stderr,end='')
                passed = result.returncode == 0 and 'PASS Sync owned family '+case in result.stdout
                results.append(dict(case=case,git=str(git.absolute()),returncode=result.returncode,passed=passed))
                (root/'build/qa/sync-owned-form-native-results.json').write_text(json.dumps(results,indent=2)+'\n')
                result.check_returncode()
                if not passed: raise RuntimeError('Sync family exited before assertions: '+case)
            except Exception as error:
                failures.append(dict(case=case,git=str(git.absolute()),error=str(error)))
                print('FAILED Sync owned family '+case+': '+str(error),flush=True)
            finally:
                sample=context/'timeout.sample.txt'
                if sample.is_file(): shutil.copyfile(sample,root/('build/qa/sync-owned-'+case+'-'+str(index)+'.sample.txt'))
                if retire_owned_helpers(context,approved) and passed:
                    results[-1].update(passed=False,helper_cleanup_needed=True)
                    (root/'build/qa/sync-owned-form-native-results.json').write_text(json.dumps(results,indent=2)+'\n')
                    raise RuntimeError('Completed Sync family left an owned helper running')

if failures:
    raise SystemExit('Sync family failures: '+json.dumps(failures))
