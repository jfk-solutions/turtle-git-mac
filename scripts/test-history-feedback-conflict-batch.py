#!/usr/bin/env python3
"""Grouped native Log feedback geometry and owned Sync conflict recovery."""
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
parser.add_argument('--only', choices=['legacy-log', 'log', 'legacy-sync', 'sync', 'conflict-report', 'resolve-files', 'resolve-drop', 'refresh'], action='append')
parser.add_argument('--results', type=Path)
parser.add_argument('--captures', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
generated = root / 'build/qa/history-feedback-conflict-native-sources'
generated.mkdir(parents=True, exist_ok=True)
legacy=[]
for name in ['log-controls-layout-native-2026-10-17.swift','sync-conflict-files-native-2026-10-17.swift', 'resolve-file-menu-native-2026-10-16.swift', 'resolve-drop-native-2026-10-16.swift', 'file-list-refresh-native-2026-10-16.swift']:
    original=root/'docs/qa'/name
    output=generated/('Retained-'+name)
    output.write_text('#sourceLocation(file: '+json.dumps(str(original))+', line: 1)\n'+original.read_text().replace('@main ', '', 1))
    legacy.append(output)
bootstrap = generated / 'HistoryFeedbackConflictMain.swift'
bootstrap.write_text(r'''import AppKit
import ObjectiveC
import TurtleGitCore
private extension NSWindow {
 @objc func turtleGitHistoryFeedbackOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  if ProcessInfo.processInfo.environment["TURTLEGIT_HISTORY_FEEDBACK_CAPTURES"] == nil {alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000))}
  turtleGitHistoryFeedbackOrder(place,relativeTo:number)
 }
}
@main struct HistoryFeedbackConflictMain {
 @MainActor static func main() async throws {
  if let status=RebaseEditor.handle(arguments:CommandLine.arguments,environment:ProcessInfo.processInfo.environment){exit(status)}
  NSApplication.shared.setActivationPolicy(.prohibited)
  let normal=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
  let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitHistoryFeedbackOrder(_:relativeTo:)))!
  method_exchangeImplementations(normal,hidden);defer{method_exchangeImplementations(normal,hidden)}
  let suite="TurtleGit.HistoryFeedback.Geometry",prefs=UserDefaults(suiteName:suite)!
  DialogGeometry.install(preferences:prefs)
  defer{DialogGeometry.install(preferences:.standard);prefs.removePersistentDomain(forName:suite)}
  let mode=ProcessInfo.processInfo.environment["TURTLEGIT_HISTORY_FEEDBACK_CASE"]!
  let base=URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL
  let git=URL(fileURLWithPath:CommandLine.arguments[2])
  switch mode {
  case "legacy-log": try await LogControlsLayoutVerification.verify()
  case "log": try await LogFeedbackStabilityVerification.verify(base:base,git:git)
  case "legacy-sync": try await SyncConflictFilesVerification.main()
  case "sync": try await SyncConflictRecoveryVerification.verify(base:base,git:git)
  case "conflict-report": try await ConflictReportVerification.verify(base:base,git:git)
  case "resolve-files": try await ResolveFileMenuVerification.main()
  case "resolve-drop": try await ResolveDropVerification.main()
  case "refresh": try await FileListRefreshVerification.verify()
  default: fatalError("Unknown history feedback case")
  }
  for _ in 0..<3000 {
   if ResolveWindowController.activeReleases==0 && ResolveWindowModel.activeOperations==0 && StatusWindowModel.activeOperations==0 && RevertWindowModel.activeOperations==0 && CommitWindowModel.activeReloads==0 && SynchronizationWindowController.activeInlineReleases==0 && NSApp.windows.allSatisfy({!$0.isVisible && $0.attachedSheet==nil}) {
    print("PASS: history feedback conflict \(mode)");return
   }
   try await Task.sleep(nanoseconds:10_000_000)
  }
  throw NSError(domain:"TurtleGit.HistoryFeedback.OwnedDrain",code:1,userInfo:[NSLocalizedDescriptionKey:"Owned native windows, sheets or workers did not drain after \(mode)"])
 }
}
''')
receiver = build_receiver(root, [root / 'docs/qa/log-feedback-stability-native-2026-11-22.swift', root / 'docs/qa/sync-conflict-recovery-native-2026-11-22.swift', root / 'docs/qa/conflict-report-native-2026-11-22.swift', *legacy, bootstrap], generated)

# Existing exact image/resource ownership policy. No helper is signalled merely
# because unrelated user argv mentions this repository or a fixture directory.
tree = ast.parse((root / 'scripts/test-editor-appearance.py').read_text())
definition = next(item for item in tree.body if isinstance(item, ast.FunctionDef) and item.name == 'retire_owned_helpers')
exec(compile(ast.Module(body=[definition], type_ignores=[]), '<history feedback ownership>', 'exec'))
result_path = args.results or root / 'build/qa/history-feedback-conflict-native-results.json'
results = []
for case in args.only or ['legacy-log', 'log', 'legacy-sync', 'sync']:
    for index, git in enumerate(args.git or [Path('/usr/bin/git'), root / 'build/git-runtime/Git/bin/git']):
        git = git.resolve()
        if not git.is_file():
            parser.error('Git executable is missing: ' + str(git))
        with tempfile.TemporaryDirectory(prefix='turtlegit-history-feedback-' + case + '-') as temporary:
            context = Path(temporary).resolve()
            for name in ['fixture', 'home', 'preferences', 'temporary', 'xdg']:
                (context / name).mkdir(mode=0o700)
            config = context / 'global.config'; config.write_text('')
            env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
            env.update(HOME=str(context / 'home'), CFFIXED_USER_HOME=str(context / 'preferences'),
                       XDG_CONFIG_HOME=str(context / 'xdg'), TMPDIR=str(context / 'temporary') + '/',
                       GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                       DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'),
                       TURTLEGIT_HISTORY_FEEDBACK_CASE=case)
            if args.captures and index==0 and case.startswith('legacy-'):
                args.captures.mkdir(parents=True,exist_ok=True)
                env['TURTLEGIT_HISTORY_FEEDBACK_CAPTURES']='1'
                env['TURTLEGIT_LOG_CONTROLS_CAPTURE' if case=='legacy-log' else 'TURTLEGIT_SYNC_CONFLICT_CAPTURE']=str(args.captures.resolve())
            approved = {str(git)}
            located = subprocess.run(['/usr/bin/xcrun', '--find', 'git'], capture_output=True, text=True)
            if located.returncode == 0:
                approved.add(str(Path(located.stdout.strip()).resolve()))
            helpers = root / 'build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers'
            if helpers.is_dir():
                approved.update(str(path.resolve()) for path in helpers.rglob('*') if path.is_file() and os.access(path, os.X_OK))
            row = dict(case=case, git=str(git), status='running')
            print('Checking history feedback/conflict ' + case + ' with ' + str(git), flush=True)
            try:
                result = run_receiver([str(receiver), str(context / 'fixture'), str(git)], cwd=root, env=env,
                                      capture_output=True, text=True, timeout=300,
                                      timeout_sample=context / 'timeout.sample.txt')
                print(result.stdout, end=''); print(result.stderr, end='')
                row['exit_code'] = result.returncode
                result.check_returncode()
                if 'PASS: history feedback conflict ' + case not in result.stdout:
                    raise RuntimeError('Native receiver exited before completing its scope')
                row['status'] = 'passed'
            except BaseException as error:
                row.update(status='failed', error=str(error)); raise
            finally:
                sample = context / 'timeout.sample.txt'
                if sample.is_file():
                    shutil.copy2(sample, root / ('build/qa/history-feedback-' + case + '-' + str(index) + '-timeout.sample.txt'))
                try:
                    row['fallback_helper_cleanup'] = retire_owned_helpers(context, approved)
                    if row['status'] == 'passed' and row['fallback_helper_cleanup']:
                        row['status'] = 'failed-owned-helper-leak'
                        raise RuntimeError('Successful history feedback case left an owned helper running')
                except BaseException as cleanup_error:
                    row.update(status='failed-owned-cleanup', cleanup_error=str(cleanup_error)); raise
                finally:
                    results.append(row)
                    result_path.parent.mkdir(parents=True, exist_ok=True)
                    result_path.write_text(json.dumps(dict(cases=results), indent=2) + '\n')
print('All selected history feedback/conflict cases passed', flush=True)
