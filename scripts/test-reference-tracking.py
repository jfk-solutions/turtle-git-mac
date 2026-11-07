#!/usr/bin/env python3
"""Tracked-branch native selection, actual Git mutation and owned sheet retirement."""
import argparse
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import tempfile
import time
from native_receiver import build_receiver, run_receiver


def retire_owned_helpers(context, approved):
    """Require an exact executable or authored wrapper plus a private resource."""
    def owned():
        scan = subprocess.run(['/usr/sbin/lsof', '-t', '+D', str(context)], capture_output=True, text=True, timeout=10)
        if scan.returncode not in (0, 1):
            raise RuntimeError('Cannot inspect private tracking helper ownership')
        result = []
        wrappers = {str(path.resolve()) for path in context.rglob('tracking-git') if path.is_file()}
        for value in set(scan.stdout.split()):
            pid = int(value)
            images = subprocess.run(['/usr/sbin/lsof', '-a', '-p', str(pid), '-d', 'txt', '-Fn'], capture_output=True, text=True, timeout=5)
            actual = {str(Path(line[1:]).resolve()) for line in images.stdout.splitlines() if line.startswith('n')}
            if actual.intersection(approved):
                result.append(pid)
                continue
            if actual.intersection({str(Path('/bin/sh').resolve()), str(Path('/bin/bash').resolve())}):
                command = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True, timeout=5).stdout.strip()
                try:
                    words = shlex.split(command)
                except ValueError:
                    continue
                if len(words) > 1 and str(Path(words[1]).resolve()) in wrappers:
                    result.append(pid)
        return result
    needed = bool(owned())
    for number in [signal.SIGTERM, signal.SIGKILL]:
        for pid in owned():
            if pid not in owned():
                continue
            try:
                os.killpg(pid, number) if os.getpgid(pid) == pid else os.kill(pid, number)
            except ProcessLookupError:
                pass
        until = time.monotonic() + 3
        while time.monotonic() < until:
            if not owned():
                return needed
            time.sleep(.03)
    raise RuntimeError('Owned tracking helper survived cleanup')


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
cache = root/'build/qa/reference-tracking-native-sources'
cache.mkdir(parents=True, exist_ok=True)
def write(path, text):
    if not path.is_file() or path.read_text() != text:
        path.write_text(text)
source = cache/'reference-tracking-native-2026-10-09.swift'
write(source, (root/'docs/qa/reference-tracking-native-2026-10-09.swift').read_text().replace('@main ', '', 1))
main = cache/'ReferenceTrackingMain.swift'
write(main, r'''import AppKit
import ObjectiveC
import TurtleGitCore
private extension NSWindow {
 @objc func trackingHiddenFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect{rect}
 @objc func trackingHiddenOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));trackingHiddenOrder(place,relativeTo:number)}
}
@main enum ReferenceTrackingMain {
 struct Failure:Error,CustomStringConvertible{let description:String}
 @MainActor static func main()async throws {
  NSApp.setActivationPolicy(.prohibited)
  let order=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.trackingHiddenOrder(_:relativeTo:)))!
  let frame=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:)))!,offscreen=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.trackingHiddenFrame(_:to:)))!
  method_exchangeImplementations(order,hidden);method_exchangeImplementations(frame,offscreen)
  defer{method_exchangeImplementations(frame,offscreen);method_exchangeImplementations(order,hidden)}
  var failure:Error?
  do{try await ReferenceTrackingVerification.verify()}catch{failure=error}
  let controllers=NSApp.windows.compactMap{$0.delegate as? ReferenceBrowserWindowController}
  controllers.forEach{$0.close()}
  for window in NSApp.windows{if let parent=window.sheetParent{parent.endSheet(window,returnCode:.abort)};window.orderOut(nil);window.close()}
  for _ in 0..<3000 {
   let reads=ReferenceBrowserWindowModel.activeReads==0 && ReferenceBrowserWindowModel.activeComparisons==0 && ReferenceBrowserWindowModel.activeFilters==0
   let mutations=ReferenceBrowserWindowModel.activeRenames==0 && ReferenceBrowserWindowModel.activeMutations==0 && LocalGitCommandProgress.activeOperations==0
   let released=ReferenceBrowserWindowController.activeChildReleases==0 && FinderFilesystemWorkflowRelease.activeRetirements==0 && controllers.allSatisfy{!$0.hasPendingWork}
   if reads && mutations && released && NSApp.windows.allSatisfy({!$0.isVisible && $0.sheetParent==nil && $0.attachedSheet==nil}) {if let failure{throw failure};print("PASS: tracked branch actual mutation and physical release completed");return}
   try await Task.sleep(nanoseconds:10_000_000)
  }
  let windows=NSApp.windows.map{"\($0.title) visible=\($0.isVisible) parent=\($0.sheetParent?.title ?? "nil") sheet=\($0.attachedSheet?.title ?? "nil")"}.joined(separator:"\n")
  throw Failure(description:"Tracking owned workers/windows did not drain; reads=\(ReferenceBrowserWindowModel.activeReads) mutations=\(ReferenceBrowserWindowModel.activeMutations) releases=\(ReferenceBrowserWindowController.activeChildReleases) retirements=\(FinderFilesystemWorkflowRelease.activeRetirements)\n"+windows+"\ninitialFailure="+String(describing:failure))
 }
}
''')
receiver = build_receiver(root, [source, main], cache)
results = []
failures = []
for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
    with tempfile.TemporaryDirectory(prefix='turtlegit-reference-tracking-') as temporary:
        context = Path(temporary).resolve()
        env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
        for name, key in [('home', 'HOME'), ('preferences', 'CFFIXED_USER_HOME'), ('xdg', 'XDG_CONFIG_HOME'), ('tmp', 'TMPDIR')]:
            folder = context/name; folder.mkdir(mode=0o700)
            env[key] = str(folder)+('/' if key == 'TMPDIR' else '')
        configuration = context/'global.config'; configuration.write_text('')
        fixture = context/'repository'; fixture.mkdir(mode=0o700)
        env.update(GIT_CONFIG_GLOBAL=str(configuration), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0', DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'))
        approved = {str(git.resolve()), str(receiver.resolve()), str(Path('/bin/sleep').resolve())}
        located = subprocess.run(['/usr/bin/xcrun', '--find', 'git'], capture_output=True, text=True)
        if located.returncode == 0:
            approved.add(str(Path(located.stdout.strip()).resolve()))
        print('Checking '+str(git), flush=True)
        passed = False
        try:
            result = run_receiver([str(receiver), str(fixture), str(git.absolute())], cwd=root, env=env, capture_output=True, text=True, timeout=300, timeout_sample=context/'timeout.sample.txt')
            print(result.stdout, end=''); print(result.stderr, end='')
            passed = result.returncode == 0 and 'PASS: tracked branch actual mutation and physical release completed' in result.stdout
            results.append(dict(git=str(git.absolute()), returncode=result.returncode, passed=passed))
            result.check_returncode()
            if not passed:
                raise RuntimeError('Tracking receiver exited before final ownership assertions')
        except Exception as error:
            failures.append(dict(git=str(git.absolute()), error=str(error)))
        finally:
            if retire_owned_helpers(context, approved):
                failures.append(dict(git=str(git.absolute()), error='Owned helper needed cleanup'))
                if passed:
                    results[-1].update(passed=False, helper_cleanup_needed=True)
            (root/'build/qa/reference-tracking-native-results.json').write_text(json.dumps(dict(results=results, failures=failures), indent=2)+'\n')
if failures:
    raise SystemExit('Tracking failures: '+json.dumps(failures))
