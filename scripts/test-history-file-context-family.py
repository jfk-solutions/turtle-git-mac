#!/usr/bin/env python3
"""One grouped native history/file menu and historical child-handoff checkpoint.

Uses actual current Debug app objects through native_receiver. Each case/Git
pair has a private process, repository, preferences, HOME, pasteboards and temp
space. The hosted history lane selects the three new context modes; retained
modes remain available for a grouped local checkpoint. No screenshot mode is used.
"""
import argparse
import ast
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time
from native_receiver import build_receiver, run_receiver

MODES = [
    'browser-context', 'blame-context', 'log-context', 'log-selection',
    'log-identities', 'log-drag-historical', 'log-drag-range', 'log-drag-working',
    'browser-files', 'blame-composition', 'blame-placement',
]
RETAINED = [
    'log-native-selection-2026-10-28.swift',
    'log-file-identities-native-2026-10-17.swift',
    'log-file-drags-native-2026-10-23.swift',
    'browser-file-actions-native-2026-10-17.swift',
    'blame-toolbar-native-2026-10-26.swift',
    'blame-toolbar-placement-native-2026-10-26.swift',
]
NEW = [
    'browser-history-context-native-2026-11-22.swift',
    'blame-toolbar-context-native-2026-11-22.swift',
    'log-file-context-native-2026-11-22.swift',
]

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=MODES, action='append')
parser.add_argument('--results', type=Path)
parser.add_argument('--keep-going', action='store_true', help='Record ordinary case failures and continue independent cases; ownership cleanup failures still stop the checkpoint.')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
generated = root / 'build/qa/history-file-context-native-sources'
generated.mkdir(parents=True, exist_ok=True)
retained = []
for name in RETAINED:
    original = root / 'docs/qa' / name
    source = re.sub(r'@main\s+', '', original.read_text(), count=1)
    if name == 'blame-toolbar-placement-native-2026-10-26.swift':
        # Its standalone main is not called here. Keep the private declaration
        # unique when both retained toolbar fixtures share this receiver module.
        source = source.replace('turtleGitBlameToolbarOrder', 'turtleGitBlameToolbarPlacementOrder')
    if name == 'log-native-selection-2026-10-28.swift':
        # Keep the exact existing shell-ownership fallback, including wrapper
        # argv, rather than broadening it to arbitrary shell commands. This is
        # only a consistent private fixture filename/marker rename.
        source = source.replace('held-history', 'held-helper')
    output = generated / ('Retained-' + name)
    output.write_text('#sourceLocation(file: ' + json.dumps(str(original)) + ', line: 1)\n' + source)
    retained.append(output)

bootstrap = generated / 'HistoryFileContextMain.swift'
bootstrap.write_text(r'''import AppKit
import ObjectiveC
import TurtleGitCore
private extension NSWindow {
 @objc func turtleGitHistoryFileContextOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0
  // Placement verifies real screen/frame persistence. Alpha zero already
  // makes it invisible; retain its actual AppKit geometry and assertions.
  if ProcessInfo.processInfo.environment["TURTLEGIT_HISTORY_FILE_CONTEXT_CASE"] != "blame-placement" {setFrameOrigin(.init(x:-24000,y:-24000))}
  turtleGitHistoryFileContextOrder(place,relativeTo:number)
 }
}
@main struct HistoryFileContextMain {
 @MainActor static func drained()->Bool {
  FileListDrag.activeLoads==0 && RepositoryBrowserExportFiles.activeLoads==0 &&
  RepositoryBrowserWindowModel.activeOperations==0 && RepositoryBrowserFileOperation.activeRequests==0 &&
  FinderFilesystemWorkflowRelease.activeRetirements==0 &&
  LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeHistoryProjectionWorkers==0 &&
  LogWindowModel.activeActionReads==0 && LogWindowModel.activeNoteReads==0 && LogWindowModel.activeNoteSaves==0 &&
  LogWindowModel.activeFileOpenReads==0 && LogWindowModel.activeWorkingCommandReads==0 &&
  LogWindowModel.activeChangedFileColumnQuestions==0 &&
  BlameDocumentOpener.activeReads==0 && BlameWindowModel.activeHistoryOperations==0 &&
  BlameWindowModel.activeSyntaxRequests==0 && BlameToolbarController.activeEditors==0 &&
  NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}
 }
 @MainActor static func waitForDrain()async throws {
  for _ in 0..<3500 {if drained(){return};try await Task.sleep(nanoseconds:10_000_000)}
  throw NSError(domain:"TurtleGit.HistoryFileContext.Drain",code:1,userInfo:[NSLocalizedDescriptionKey:"Owned native windows, sheets, requests or toolbar editors did not drain"])
 }
 @MainActor static func run(_ mode:String,base:URL,git:URL)async throws {
  switch mode {
  case "browser-context":try await BrowserHistoryContextVerification.verify(base:base,git:git)
  case "blame-context":try await BlameToolbarContextVerification.verify(base:base,git:git)
  case "log-context":try await LogFileContextVerification.verify(base:base,git:git)
  case "log-selection":try await LogNativeSelectionVerification.main()
  case "log-identities":try await LogFileIdentitiesVerification.verify()
  case "log-drag-historical","log-drag-range","log-drag-working":await LogFileDragsVerification.main()
  case "browser-files":try await BrowserFileActionsVerification.verify()
  case "blame-composition":
   do {try await BlameToolbarVerification.verify();await BlameToolbarVerification.cleanup();try BlameToolbarVerification.require(BlameToolbarVerification.drained(),"Composition workers survived cleanup")}
   catch {await BlameToolbarVerification.cleanup();throw error}
  case "blame-placement":
   do {try await BlameToolbarPlacementVerification.verify();await BlameToolbarPlacementVerification.cleanup();try BlameToolbarPlacementVerification.require(BlameToolbarPlacementVerification.drained(),"Placement workers survived cleanup")}
   catch {await BlameToolbarPlacementVerification.cleanup();throw error}
  default:throw NSError(domain:"TurtleGit.HistoryFileContext.Mode",code:1,userInfo:[NSLocalizedDescriptionKey:"Unknown grouped mode"])
  }
 }
 @MainActor static func main()async throws {
  if let status=RebaseEditor.handle(arguments:CommandLine.arguments,environment:ProcessInfo.processInfo.environment){exit(status)}
  NSApplication.shared.setActivationPolicy(.prohibited)
  let normal=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
  let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitHistoryFileContextOrder(_:relativeTo:)))!
  method_exchangeImplementations(normal,hidden);defer{method_exchangeImplementations(normal,hidden)}
  let suite="TurtleGit.HistoryFileContext.Geometry",preferences=UserDefaults(suiteName:suite)!
  DialogGeometry.install(preferences:preferences)
  defer{DialogGeometry.install(preferences:.standard);preferences.removePersistentDomain(forName:suite)}
  let mode=ProcessInfo.processInfo.environment["TURTLEGIT_HISTORY_FILE_CONTEXT_CASE"]!
  let base=URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL
  let git=URL(fileURLWithPath:CommandLine.arguments[2])
  do {
   try await run(mode,base:base,git:git)
   try await waitForDrain()
   print("PASS: history file context "+mode);fflush(stdout)
  } catch {
   let original=error
   // This receiver process owns all its windows. Controller closure preserves
   // each feature's real cancellation/drain behavior; no user app is targeted.
   for window in NSApp.windows {
    if let controller=window.windowController {controller.close()}
    else {window.isReleasedWhenClosed=false;window.orderOut(nil);window.close()}
   }
   do {try await waitForDrain()} catch {throw NSError(domain:"TurtleGit.HistoryFileContext.Failure",code:1,userInfo:[NSLocalizedDescriptionKey:String(describing:original)+"; cleanup: "+String(describing:error)])}
   throw original
  }
 }
}
''')
receiver = build_receiver(root, [*(root / 'docs/qa' / name for name in NEW), *retained, bootstrap], generated)

# Import only the established exact executable/resource/shell-argv ownership
# function; never execute another driver's parser or run its test cases.
tree = ast.parse((root / 'scripts/test-editor-appearance.py').read_text())
definition = next(item for item in tree.body if isinstance(item, ast.FunctionDef) and item.name == 'retire_owned_helpers')
exec(compile(ast.Module(body=[definition], type_ignores=[]), '<history file context ownership>', 'exec'))
result_path = args.results or root / 'build/qa/history-file-context-native-results.json'
results = []
for case in args.only or MODES:
    for index, git in enumerate(args.git or [Path('/usr/bin/git'), root / 'build/git-runtime/Git/bin/git']):
        git = git.absolute()
        if not git.is_file():
            parser.error('Git executable is missing: ' + str(git))
        with tempfile.TemporaryDirectory(prefix='turtlegit-history-file-' + case + '-') as temporary:
            # Preserve the native /var spelling supplied by tempfile. Resolving
            # this CLI parent to /private/var changes retained URL oracles even
            # though Foundation standardizes GitRepository.root back to /var.
            context = Path(temporary)
            for name in ['fixture', 'home', 'preferences', 'temporary', 'xdg']:
                (context / name).mkdir(mode=0o700)
            config = context / 'global.config'; config.write_text('')
            env = {key: value for key, value in os.environ.items() if not key.startswith(('GIT_', 'TURTLEGIT_'))}
            env.update(HOME=str(context / 'home'), CFFIXED_USER_HOME=str(context / 'preferences'),
                       XDG_CONFIG_HOME=str(context / 'xdg'), TMPDIR=str(context / 'temporary') + '/',
                       GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                       DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'),
                       TURTLEGIT_HISTORY_FILE_CONTEXT_CASE=case)
            approved = {str(git.resolve())}
            located = subprocess.run(['/usr/bin/xcrun', '--find', 'git'], capture_output=True, text=True)
            if located.returncode == 0:
                approved.add(str(Path(located.stdout.strip()).resolve()))
            app = root / 'build/Build/Products/Debug/TurtleGitMac.app/Contents'
            helpers = app / 'Helpers'
            if helpers.is_dir():
                approved.update(str(path.resolve()) for path in helpers.rglob('*') if path.is_file() and os.access(path, os.X_OK))
            macos = app / 'MacOS'
            if macos.is_dir():
                approved.update(str(path.resolve()) for path in macos.glob('TurtleGitRuntime-*') if path.is_file() and os.access(path, os.X_OK))
            command = [str(receiver), str(context / 'fixture'), str(git)]
            if case.startswith('log-drag-'):
                command.append(case.removeprefix('log-drag-'))
            started = time.monotonic()
            row = dict(case=case, git=str(git), status='running', started_utc=datetime.now(timezone.utc).isoformat())
            print('Checking history file context ' + case + ' with ' + str(git), flush=True)
            try:
                result = run_receiver(command, cwd=root, env=env, capture_output=True, text=True,
                                      timeout=420, timeout_sample=context / 'timeout.sample.txt')
                print(result.stdout, end=''); print(result.stderr, end='')
                row['exit_code'] = result.returncode
                result.check_returncode()
                if 'PASS: history file context ' + case not in result.stdout:
                    raise RuntimeError('Native receiver exited before completing its mode and owned drainage')
                row['status'] = 'passed'
            except BaseException as error:
                row.update(status='failed', error=str(error))
                if not args.keep_going or not isinstance(error, Exception):
                    raise
            finally:
                sample = context / 'timeout.sample.txt'
                if sample.is_file():
                    shutil.copy2(sample, root / ('build/qa/history-file-context-' + case + '-' + str(index) + '-timeout.sample.txt'))
                try:
                    row['fallback_helper_cleanup'] = retire_owned_helpers(context, approved)
                    if row['status'] == 'passed' and row['fallback_helper_cleanup']:
                        row['status'] = 'failed-owned-helper-leak'
                        raise RuntimeError('Successful context mode left a verified private helper running')
                except BaseException as cleanup_error:
                    row.update(status='failed-owned-cleanup', cleanup_error=str(cleanup_error)); raise
                finally:
                    row['elapsed_seconds'] = round(time.monotonic() - started, 3)
                    results.append(row)
                    result_path.parent.mkdir(parents=True, exist_ok=True)
                    result_path.write_text(json.dumps(dict(cases=results), indent=2) + '\n')
failed = [row for row in results if row['status'] != 'passed']
if failed:
    print(str(len(failed)) + ' history file context cases failed; see ' + str(result_path), flush=True)
    raise SystemExit(1)
print('All selected history file context cases passed', flush=True)
