#!/usr/bin/env python3
"""One grouped native mixed Log primary/conflict launch ownership checkpoint.

Private repositories/preferences/HOME/pasteboards, current Debug app objects,
exact receiver cache and owned helper cleanup. Does not build the application.
"""
import argparse
import ast
from datetime import datetime,timezone
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time
from native_receiver import build_receiver,run_receiver

MODES=['primary','conflict-routing','conflict-commands','image-conflict']
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--only',choices=MODES,action='append')
parser.add_argument('--results',type=Path)
parser.add_argument('--keep-going',action='store_true')
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
new=root/'docs/qa/log-primary-activation-native-2026-11-22.swift'
generated=root/'build/qa/log-primary-activation-native-sources';generated.mkdir(parents=True,exist_ok=True)
retained=[]
for name in ['conflict-editor-routing-native-2026-10-14.swift','conflict-commands-native-2026-10-18.swift','image-conflict-owned-native-2026-10-16.swift']:
    original=root/'docs/qa'/name
    source=re.sub(r'@main\s+','',original.read_text(),count=1)
    output=generated/('Retained-'+name)
    output.write_text('#sourceLocation(file: '+json.dumps(str(original))+', line: 1)\n'+source)
    retained.append(output)
primary=root/'docs/qa/primary-commands-native-2026-10-18.swift'
primary_source=primary.read_text()
assertions=primary_source.split('    @MainActor static func verifyNetwork',1)[0].replace('@main ','',1)
# The retained conflict-command extension uses the original cardinality assertion
# declared after verifyNetwork; keep its exact implementation, not a weaker shim.
require_one=primary_source.split('    static func requireOne<T>',1)[1].split('    @MainActor static func verifyIO',1)[0]
assertions+='    static func requireOne<T>'+require_one+'}\n'
helper=generated/'PrimaryCommandsAssertions.swift';helper.write_text('#sourceLocation(file: '+json.dumps(str(primary))+', line: 1)\n'+assertions)
retained.append(helper)
bootstrap=generated/'LogPrimaryActivationMain.swift'
bootstrap.write_text(r'''import AppKit
import ObjectiveC
import TurtleGitCore
private extension NSWindow {
 @objc func turtleGitPrimaryOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));turtleGitPrimaryOrder(place,relativeTo:number)
 }
}
@main struct LogPrimaryActivationMain {
 @MainActor static func drained()->Bool {
  FileListComparisonSession.activeOperations==0 && MergeToolApplication.activeRequests==0 && ExternalToolProcesses.activeRequests==0 &&
  LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeHistoryProjectionWorkers==0 && LogWindowModel.activeActionReads==0 &&
  LogWindowModel.activeFileOpenReads==0 && LogWindowModel.activeFileNavigationActivities==0 &&
  ImageConflictWindowModel.activeOperations==0 && ConflictReviewOperation.activeOperations==0 &&
  MergeExternalReloadCoordinator.activeRequests==0 && MergeEditorOpenWorkflow.activeTransactions==0 && MergeEditorOpenWorkflow.activeSaves==0 && MergeSourceExport.activeExports==0 &&
  FinderFilesystemWorkflowRelease.activeRetirements==0 &&
  NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil && ($0.delegate as? TextConflictWindowController)?.mergeToolHasPendingWork != true}
 }
 @MainActor static func drain()async throws {
  for _ in 0..<3500 {if drained(){return};try await Task.sleep(nanoseconds:10_000_000)}
  throw NSError(domain:"TurtleGit.LogPrimary.Drain",code:1,userInfo:[NSLocalizedDescriptionKey:"Owned launch/child/window resources did not drain"])
 }
 @MainActor static func main()async throws {
  if let status=RebaseEditor.handle(arguments:CommandLine.arguments,environment:ProcessInfo.processInfo.environment){exit(status)}
  NSApplication.shared.setActivationPolicy(.prohibited)
  let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
  let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitPrimaryOrder(_:relativeTo:)))!
  method_exchangeImplementations(original,hidden);defer{method_exchangeImplementations(original,hidden)}
  let suite="TurtleGit.LogPrimary.Geometry",preferences=UserDefaults(suiteName:suite)!
  DialogGeometry.install(preferences:preferences)
  defer{DialogGeometry.install(preferences:.standard);preferences.removePersistentDomain(forName:suite)}
  let mode=ProcessInfo.processInfo.environment["TURTLEGIT_LOG_PRIMARY_CASE"]!
  let base=URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL,git=URL(fileURLWithPath:CommandLine.arguments[2])
  do {
   switch mode {
   case "primary":try await LogPrimaryActivationVerification.verify(base:base,git:git)
   case "conflict-routing":try await ConflictEditorRoutingVerification.verify()
   case "conflict-commands":try await PrimaryCommandsVerification.verifyConflictCommands()
   case "image-conflict":try await ImageConflictOwnedVerification.verify()
   default:throw NSError(domain:"TurtleGit.LogPrimary.Mode",code:1)
   }
   try await drain();print("PASS: log primary activation "+mode);fflush(stdout)
  } catch {
   let original=error
   for window in NSApp.windows {if let controller=window.windowController {controller.close()} else {window.isReleasedWhenClosed=false;window.orderOut(nil);window.close()}}
   do {try await drain()} catch {throw NSError(domain:"TurtleGit.LogPrimary.Failure",code:1,userInfo:[NSLocalizedDescriptionKey:String(describing:original)+"; cleanup: "+String(describing:error)])}
   throw original
  }
 }
}
''')
receiver=build_receiver(root,[new,*retained,bootstrap],generated)

# Import only the established exact executable/resource/shell-argv ownership
# function; never execute another driver's parser or run its test cases.
tree = ast.parse((root / 'scripts/test-editor-appearance.py').read_text())
definition = next(item for item in tree.body if isinstance(item, ast.FunctionDef) and item.name == 'retire_owned_helpers')
exec(compile(ast.Module(body=[definition], type_ignores=[]), '<log primary activation ownership>', 'exec'))
result_path = args.results or root / 'build/qa/log-primary-activation-native-results.json'
results = []
for case in args.only or MODES:
    for index, git in enumerate(args.git or [Path('/usr/bin/git'), root / 'build/git-runtime/Git/bin/git']):
        git = git.absolute()
        if not git.is_file():
            parser.error('Git executable is missing: ' + str(git))
        with tempfile.TemporaryDirectory(prefix='turtlegit-log-primary-' + case + '-') as temporary:
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
                       TURTLEGIT_LOG_PRIMARY_CASE=case)
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
            started = time.monotonic()
            row = dict(case=case, git=str(git), status='running', started_utc=datetime.now(timezone.utc).isoformat())
            print('Checking log primary activation ' + case + ' with ' + str(git), flush=True)
            try:
                result = run_receiver(command, cwd=root, env=env, capture_output=True, text=True,
                                      timeout=420, timeout_sample=context / 'timeout.sample.txt')
                print(result.stdout, end=''); print(result.stderr, end='')
                row['exit_code'] = result.returncode
                result.check_returncode()
                if 'PASS: log primary activation ' + case not in result.stdout:
                    raise RuntimeError('Native receiver exited before completing its mode and owned drainage')
                row['status'] = 'passed'
            except BaseException as error:
                row.update(status='failed', error=str(error))
                if not args.keep_going or not isinstance(error, Exception):
                    raise
            finally:
                sample = context / 'timeout.sample.txt'
                if sample.is_file():
                    shutil.copy2(sample, root / ('build/qa/log-primary-activation-' + case + '-' + str(index) + '-timeout.sample.txt'))
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
    print(str(len(failed)) + ' log primary activation cases failed; see ' + str(result_path), flush=True)
    raise SystemExit(1)
print('All selected log primary activation cases passed', flush=True)
