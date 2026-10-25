#!/usr/bin/env python3
"""Grouped native embedded patch, comparison and conflict appearance ownership."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
from native_receiver import build_receiver, run_receiver

def retire_owned_helpers(context, approved_images):
    """Require both an exact executable and an open private fixture resource.

    Shell ownership additionally requires the exact authored wrapper argv. No
    unrelated application or process merely mentioning a fixture path is killed.
    """
    wrapper = context / 'fixture/held-helper'

    def owned():
        listing = subprocess.run(['/usr/sbin/lsof', '-t', '+D', str(context)],
                                 capture_output=True, text=True, timeout=10)
        if listing.returncode not in (0, 1):
            raise RuntimeError('Cannot inspect private handoff helper ownership')
        result = []
        for text in set(listing.stdout.split()):
            pid = int(text)
            executable = subprocess.run(['/usr/sbin/lsof', '-a', '-p', str(pid), '-d', 'txt', '-Fn'],
                                        capture_output=True, text=True, timeout=5)
            images = {str(Path(line[1:]).resolve()) for line in executable.stdout.splitlines() if line.startswith('n')}
            if images.intersection(approved_images):
                result.append(pid)
            elif str(Path('/bin/sh').resolve()) in images or '/bin/bash' in images:
                args = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'command='],
                                      capture_output=True, text=True, timeout=5).stdout.strip()
                if args.startswith('/bin/sh ' + str(wrapper) + ' ') or args == '/bin/sh ' + str(wrapper):
                    result.append(pid)
        return result

    needed = bool(owned())
    for number in (signal.SIGTERM, signal.SIGKILL):
        for pid in owned():
            if pid not in owned():
                continue
            try:
                group = os.getpgid(pid)
                os.killpg(group, number) if group == pid else os.kill(pid, number)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 3
        while owned() and time.monotonic() < deadline:
            time.sleep(.03)
        if not owned():
            return needed
    raise RuntimeError('Verified private handoff producer survived cleanup')


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--only',choices=['commit','compare','merge'],action='append')
parser.add_argument('--capture-dir',type=Path,help='Public view-render captures of owned offscreen surfaces, first engine only')
parser.add_argument('--results',type=Path)
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
generated=root/'build/qa/editor-appearance-native-sources'
generated.mkdir(parents=True,exist_ok=True)
main=generated/'EditorAppearanceMain.swift'
source=r'''import AppKit
import ObjectiveC
private extension NSWindow {
 @objc func turtleGitAppearanceOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;setFrameOrigin(.init(x:-12000,y:-12000));turtleGitAppearanceOrder(place,relativeTo:number)
 }
}
@main struct EditorAppearanceMain {
 @MainActor static func main()async throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
  let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitAppearanceOrder(_:relativeTo:)))!
  method_exchangeImplementations(original,hidden)
  defer{method_exchangeImplementations(original,hidden)}
  let mode=ProcessInfo.processInfo.environment["TURTLEGIT_APPEARANCE_CASE"]!
  try await EditorAppearanceVerification.run(mode)
  print("PASS: editor appearance \(mode)")
 }
}
'''
if not main.is_file() or main.read_text()!=source:main.write_text(source)
receiver=build_receiver(root,[root/'docs/qa/editor-appearance-native-2026-10-25.swift',main],generated)
results=[]
engines=args.git or [Path('/usr/bin/git'),root/'build/git-runtime/Git/bin/git']
for case in args.only or ['commit','compare','merge']:
 for index,git in enumerate(engines):
  git=git.absolute()
  with tempfile.TemporaryDirectory(prefix='turtlegit-editor-appearance-') as temporary:
   directory=Path(temporary);fixture=directory/'fixture';fixture.mkdir();private_tmp=directory/'temporary';private_tmp.mkdir(mode=0o700)
   config=directory/'global.config';config.write_text('')
   env={key:value for key,value in os.environ.items() if not key.startswith('GIT_') and key!='TURTLEGIT_APPEARANCE_CAPTURE'}
   env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=str(config),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',XDG_CONFIG_HOME=str(directory/'xdg'),TMPDIR=str(private_tmp),TURTLEGIT_APPEARANCE_CASE=case)
   if args.capture_dir and index==0:env['TURTLEGIT_APPEARANCE_CAPTURE']=str(args.capture_dir.absolute())
   approved={str(git.resolve())}
   helpers=root/'build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers'
   if helpers.is_dir():approved.update(str(path.resolve()) for path in helpers.rglob('*') if path.is_file() and os.access(path,os.X_OK))
   print('Checking editor appearance '+case+' with '+str(git),flush=True)
   row=dict(case=case,git=str(git),status='running')
   try:
    result=run_receiver([str(receiver),str(fixture),str(git)],cwd=root,env=env,capture_output=True,text=True,timeout=360,timeout_sample=directory/'timeout.sample.txt')
    print(result.stdout,end='');print(result.stderr,end='');row.update(exit_code=result.returncode)
    result.check_returncode()
    if 'PASS: editor appearance '+case not in result.stdout:raise RuntimeError('Receiver exited before completion')
    row['status']='passed'
   except BaseException as error:
    row.update(status='failed',error=str(error));raise
   finally:
    row['fallback_helper_cleanup']=retire_owned_helpers(directory,approved)
    results.append(row)
    if args.results:
     args.results.parent.mkdir(parents=True,exist_ok=True);args.results.write_text(json.dumps(dict(cases=results),indent=2)+'\n')
print('All selected editor appearance pairs passed',flush=True)
