#!/usr/bin/env python3
"""Grouped private RefLog refresh, list, deletion and partial-failure workflows."""
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
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['lifecycle', 'table', 'deletion', 'partial'], action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
cases = {
    'lifecycle': ('reflog-lifecycle-native-2026-10-16.swift', 'RefLogLifecycleVerification', 'verify', 'PASS: RefLog missing-ref'),
    'table': ('reflog-table-native-2026-10-13.swift', 'RefLogTableVerification', 'verify', 'RefLog native table:'),
    'deletion': ('reflog-deletion-native-2026-10-08.swift', 'ReferenceLogDeletionVerification', 'main', 'RefLog deletion: source'),
    'partial': ('reflog-partial-failure-native-2026-10-08.swift', 'ReferenceLogPartialFailureVerification', 'main', 'RefLog partial failure: real'),
}
# Reuse the exact-executable/private-resource rule, extending only the authored
# wrapper allowlist for this family. The protected reference-batch driver is unused.
cleanup_tree = ast.parse((root / 'scripts/test-log-file-drags.py').read_text())
cleanup = next(node for node in cleanup_tree.body if isinstance(node, ast.FunctionDef) and node.name == 'retire_owned_helpers')
cleanup_source = ast.unparse(cleanup)
if cleanup_source.count("wrapper = context / 'fixture/held-helper'") != 1 or cleanup_source.count("if args.startswith('/bin/sh ' + str(wrapper) + ' ') or args == '/bin/sh ' + str(wrapper):") != 1:
    raise RuntimeError('Exact owned-helper allowlist shape changed; refusing unadapted cleanup')
cleanup_source = cleanup_source.replace("wrapper = context / 'fixture/held-helper'", "wrappers = [context / 'fixture/lifecycle-git', context / 'fixture/fail-delete.sh']")
cleanup_source = cleanup_source.replace("if args.startswith('/bin/sh ' + str(wrapper) + ' ') or args == '/bin/sh ' + str(wrapper):", "if any(args.startswith('/bin/sh ' + str(wrapper) + ' ') or args == '/bin/sh ' + str(wrapper) for wrapper in wrappers):")
namespace = dict(os=os, signal=signal, time=time, subprocess=subprocess, Path=Path)
exec(compile(cleanup_source, '<owned RefLog helpers>', 'exec'), namespace)
retire_owned_helpers = namespace['retire_owned_helpers']
inputs = root / 'build/qa/reflog-lifecycle-family-inputs'
inputs.mkdir(parents=True, exist_ok=True)
sources = []
for filename, _, _, _ in cases.values():
    original = root / 'docs/qa' / filename
    text = '#sourceLocation(file: ' + json.dumps(str(original)) + ', line: 1)\n' + original.read_text().replace('@main ', '', 1)
    target = inputs / filename
    if not target.is_file() or target.read_text() != text:
        target.write_text(text)
    sources.append(target)
main = inputs / 'RefLogFamilyMain.swift'
text = '''import AppKit
import ObjectiveC
private extension NSWindow {
 @objc func turtleGitRefLogOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));turtleGitRefLogOrder(place,relativeTo:number)
 }
 @objc func turtleGitRefLogConstrain(_ frame:NSRect,to screen:NSScreen?)->NSRect {frame}
}
@main struct RefLogFamilyMain {
 @MainActor static func cleanup()async throws {
  for window in NSApp.windows {if let parent=window.sheetParent {parent.endSheet(window,returnCode:.cancel)};window.close()}
  for _ in 0..<3000 {
   if ReferenceLogWindowModel.activeOwnedOperations==0,ReferenceLogWindowModel.activeRevisionReads==0,
      NSApp.windows.allSatisfy({!$0.isVisible && $0.sheetParent==nil && $0.attachedSheet==nil}) {return}
   try await Task.sleep(nanoseconds:10_000_000)
  }
  throw NSError(domain:"TurtleGit.RefLogFamily",code:1,userInfo:[NSLocalizedDescriptionKey:"Owned RefLog windows/readers did not drain"])
 }
 @MainActor static func main()async throws {
  NSApp.setActivationPolicy(.prohibited)
  let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
  let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitRefLogOrder(_:relativeTo:)))!
  let constrain=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:)))!
  let offscreen=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitRefLogConstrain(_:to:)))!
  method_exchangeImplementations(original,hidden);method_exchangeImplementations(constrain,offscreen)
  defer {method_exchangeImplementations(original,hidden);method_exchangeImplementations(constrain,offscreen)}
  do {switch CommandLine.arguments[3] {
''' + ''.join('case "' + case + '": try await ' + kind + '.' + entry + '()\n' for case, (_, kind, entry, _) in cases.items()) + '''default:fatalError("Unknown RefLog family case")
   };try await cleanup()
  } catch {let failure=error;do {try await cleanup()}catch {throw NSError(domain:"TurtleGit.RefLogFamily",code:2,userInfo:[NSLocalizedDescriptionKey:"\\(failure); cleanup: \\(error)"])};throw failure}
  print("PASS: RefLog connected family completed")
 }
}
'''
if not main.is_file() or main.read_text() != text:
    main.write_text(text)
receiver = build_receiver(root, sources + [main], inputs)
with tempfile.TemporaryDirectory(prefix='tg-reflog-family-') as temporary:
    directory = Path(temporary)
    environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    environment.update(DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for case in args.only or cases:
        marker = cases[case][3]
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            context = directory / (case + str(index))
            context.mkdir()
            for name in ['fixture', 'home', 'preferences', 'temporary', 'xdg']:
                (context / name).mkdir(mode=0o700)
            fixture = context / 'fixture'
            config = context / 'global.config'
            config.write_text('')
            active = dict(environment, HOME=str(context / 'home'), CFFIXED_USER_HOME=str(context / 'preferences'), TMPDIR=str(context / 'temporary') + '/', XDG_CONFIG_HOME=str(context / 'xdg'), GIT_CONFIG_GLOBAL=str(config))
            print('Checking RefLog ' + case + ' with ' + str(git), flush=True)
            approved = {str(git.resolve()), str(Path('/usr/bin/git').resolve())}
            passed = False
            retained = False
            def retain(error=None):
                evidence_root = root / 'build/qa/native-reflog-family-failures'
                evidence_root.mkdir(parents=True, exist_ok=True)
                evidence = Path(tempfile.mkdtemp(prefix=case + '-' + str(index) + '-', dir=evidence_root))
                if error is not None:
                    for name in ['stdout', 'stderr']:
                        output = getattr(error, name, None)
                        if output is not None and not (context / (name + '.log')).exists():
                            (context / (name + '.log')).write_text(output.decode('utf-8', errors='replace') if isinstance(output, bytes) else output)
                shutil.copytree(context, evidence, dirs_exist_ok=True, symlinks=True)
                print('Retained private RefLog failure: ' + str(evidence), flush=True)
            try:
                result = run_receiver([str(receiver), str(fixture), str(git.absolute()), case], cwd=root, env=active, capture_output=True, text=True, timeout=300, timeout_sample=context / 'timeout.sample.txt')
                (context / 'stdout.log').write_text(result.stdout)
                (context / 'stderr.log').write_text(result.stderr)
                print(result.stdout, end=''); print(result.stderr, end='')
                result.check_returncode()
                passed = marker in result.stdout and 'PASS: RefLog connected family completed' in result.stdout
                if not passed:
                    raise RuntimeError('Receiver exited before RefLog final assertions/drain: ' + case)
            except BaseException as error:
                retain(error); retained = True; raise
            finally:
                try:
                    if retire_owned_helpers(context, approved) and passed:
                        raise RuntimeError('Successful RefLog case left an owned helper: ' + case)
                except BaseException:
                    if not retained:
                        retain()
                    raise
