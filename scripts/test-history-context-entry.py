#!/usr/bin/env python3
"""Actual native Add/Sync/Blame contextual keyboard and selection workflow."""
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
parser.add_argument('--only', choices=['add', 'sync', 'blame'], action='append')
parser.add_argument('--results', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
generated = root / 'build/qa/history-context-entry-native-sources'
generated.mkdir(parents=True, exist_ok=True)
bootstrap = generated / 'HistoryContextEntryMain.swift'
bootstrap.write_text(r'''import AppKit
import ObjectiveC
private extension NSWindow {
 @objc func turtleGitContextEntryOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));turtleGitContextEntryOrder(place,relativeTo:number)
 }
}
@main struct HistoryContextEntryMain {
 @MainActor static func main() async throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let normal=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
  let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitContextEntryOrder(_:relativeTo:)))!
  method_exchangeImplementations(normal,hidden);defer{method_exchangeImplementations(normal,hidden)}
  let suite="TurtleGit.ContextEntry.Geometry",prefs=UserDefaults(suiteName:suite)!
  DialogGeometry.install(preferences:prefs)
  defer{DialogGeometry.install(preferences:.standard);prefs.removePersistentDomain(forName:suite)}
  let mode=ProcessInfo.processInfo.environment["TURTLEGIT_CONTEXT_ENTRY_CASE"]!
  try await HistoryContextEntryVerification.run(mode)
  print("PASS: history contextual entry \(mode)")
 }
}
''')
receiver = build_receiver(root, [root / 'docs/qa/history-context-entry-native-2026-11-22.swift', bootstrap], generated)

# Existing exact image/resource ownership policy. No helper is signalled merely
# because unrelated user argv mentions this repository or a fixture directory.
tree = ast.parse((root / 'scripts/test-editor-appearance.py').read_text())
definition = next(item for item in tree.body if isinstance(item, ast.FunctionDef) and item.name == 'retire_owned_helpers')
exec(compile(ast.Module(body=[definition], type_ignores=[]), '<context entry ownership>', 'exec'))
result_path = args.results or root / 'build/qa/history-context-entry-native-results.json'
results = []
for case in args.only or ['add', 'sync', 'blame']:
    for index, git in enumerate(args.git or [Path('/usr/bin/git'), root / 'build/git-runtime/Git/bin/git']):
        git = git.resolve()
        if not git.is_file():
            parser.error('Git executable is missing: ' + str(git))
        with tempfile.TemporaryDirectory(prefix='turtlegit-context-entry-' + case + '-') as temporary:
            context = Path(temporary).resolve()
            for name in ['fixture', 'home', 'preferences', 'temporary', 'xdg']:
                (context / name).mkdir(mode=0o700)
            config = context / 'global.config'; config.write_text('')
            env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
            env.update(HOME=str(context / 'home'), CFFIXED_USER_HOME=str(context / 'preferences'),
                       XDG_CONFIG_HOME=str(context / 'xdg'), TMPDIR=str(context / 'temporary') + '/',
                       GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                       DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'),
                       TURTLEGIT_CONTEXT_ENTRY_CASE=case)
            approved = {str(git)}
            located = subprocess.run(['/usr/bin/xcrun', '--find', 'git'], capture_output=True, text=True)
            if located.returncode == 0:
                approved.add(str(Path(located.stdout.strip()).resolve()))
            helpers = root / 'build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers'
            if helpers.is_dir():
                approved.update(str(path.resolve()) for path in helpers.rglob('*') if path.is_file() and os.access(path, os.X_OK))
            row = dict(case=case, git=str(git), status='running')
            print('Checking contextual entry ' + case + ' with ' + str(git), flush=True)
            try:
                result = run_receiver([str(receiver), str(context / 'fixture'), str(git)], cwd=root, env=env,
                                      capture_output=True, text=True, timeout=300,
                                      timeout_sample=context / 'timeout.sample.txt')
                print(result.stdout, end=''); print(result.stderr, end='')
                row['exit_code'] = result.returncode
                result.check_returncode()
                if 'PASS: history contextual entry ' + case not in result.stdout:
                    raise RuntimeError('Native receiver exited before completing its scope')
                row['status'] = 'passed'
            except BaseException as error:
                row.update(status='failed', error=str(error)); raise
            finally:
                sample = context / 'timeout.sample.txt'
                if sample.is_file():
                    shutil.copy2(sample, root / ('build/qa/context-entry-' + case + '-' + str(index) + '-timeout.sample.txt'))
                try:
                    row['fallback_helper_cleanup'] = retire_owned_helpers(context, approved)
                    if row['status'] == 'passed' and row['fallback_helper_cleanup']:
                        row['status'] = 'failed-owned-helper-leak'
                        raise RuntimeError('Successful context case left an owned helper running')
                except BaseException as cleanup_error:
                    row.update(status='failed-owned-cleanup', cleanup_error=str(cleanup_error)); raise
                finally:
                    results.append(row)
                    result_path.parent.mkdir(parents=True, exist_ok=True)
                    result_path.write_text(json.dumps(dict(cases=results), indent=2) + '\n')
print('All selected contextual entry cases passed', flush=True)
