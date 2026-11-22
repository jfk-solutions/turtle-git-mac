#!/usr/bin/env python3
"""Grouped actual Compare/Merge Save completion, history and pane ownership."""
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
parser.add_argument('--only', choices=['compare', 'merge', 'blocks', 'save-as'], action='append')
parser.add_argument('--layout', choices=['classic', 'p4'], action='append', help='Limit the new editor cases; retained cases keep their full scope.')
parser.add_argument('--results', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
generated = root / 'build/qa/editor-save-history-readiness-native-sources'
generated.mkdir(parents=True, exist_ok=True)
bootstrap = generated / 'EditorSaveHistoryReadinessMain.swift'
bootstrap.write_text(r'''import AppKit
import ObjectiveC
private extension NSWindow {
 @objc func turtleGitSaveHistoryOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));turtleGitSaveHistoryOrder(place,relativeTo:number)
 }
}
@main struct EditorSaveHistoryReadinessMain {
 @MainActor static func main() async throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let normal=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
  let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitSaveHistoryOrder(_:relativeTo:)))!
  method_exchangeImplementations(normal,hidden);defer{method_exchangeImplementations(normal,hidden)}
  let suite="TurtleGit.SaveHistory.Geometry",prefs=UserDefaults(suiteName:suite)!
  DialogGeometry.install(preferences:prefs)
  defer{DialogGeometry.install(preferences:.standard);prefs.removePersistentDomain(forName:suite)}
  let mode=ProcessInfo.processInfo.environment["TURTLEGIT_EDITOR_SAVE_HISTORY_CASE"]!
  @MainActor func finish() async throws {
   let cleanup=EditorSaveHistoryReadinessVerification.Context()
   defer{cleanup.prefs.removePersistentDomain(forName:cleanup.suite)}
   try await cleanup.cleanup()
  }
  do {
   switch mode {
   case "blocks":try await MergeSourceBlocksVerification.verify()
   case "save-as":try await SaveAsTargetsVerification.main()
   default:try await EditorSaveHistoryReadinessVerification.run(mode)
   }
  } catch {
   let original=error
   do{try await finish()}catch{throw EditorSaveHistoryReadinessVerification.Failure(description:"\(original); retained cleanup: \(error)")}
   throw original
  }
  try await finish()
  print("PASS: editor Save/history readiness \(mode)")
 }
}
''')
fixtures = [root / 'docs/qa/editor-save-history-readiness-native-2026-11-22.swift']
for filename in ['merge-source-blocks-native-2026-10-16.swift', 'save-as-targets-native-2026-10-15.swift', 'three-pane-engine-native-2026-10-12.swift']:
    target = generated / filename
    target.write_text((root / 'docs/qa' / filename).read_text().replace('@main ', '', 1))
    fixtures.append(target)
receiver = build_receiver(root, fixtures + [bootstrap], generated)

# Reuse the exact existing image/resource ownership cleanup policy. A helper is
# never signalled solely because its argv happens to mention a fixture path.
tree = ast.parse((root / 'scripts/test-editor-appearance.py').read_text())
definition = next(item for item in tree.body if isinstance(item, ast.FunctionDef) and item.name == 'retire_owned_helpers')
exec(compile(ast.Module(body=[definition], type_ignores=[]), '<editor helper ownership>', 'exec'))
results = []
result_path = args.results or root / 'build/qa/editor-save-history-readiness-native-results.json'
matrix = [(case, layout) for case in args.only or ['compare', 'merge', 'blocks', 'save-as']
          for layout in ((args.layout or ['classic', 'p4']) if case in ['compare', 'merge'] else ['retained'])]
for case, layout in matrix:
    for index, git in enumerate(args.git or [Path('/usr/bin/git'), root / 'build/git-runtime/Git/bin/git']):
        git = git.resolve()
        if not git.is_file():
            parser.error('Git executable is missing: ' + str(git))
        with tempfile.TemporaryDirectory(prefix='turtlegit-save-history-' + case + '-' + layout + '-') as temporary:
            context = Path(temporary).resolve()
            for name in ['fixture', 'home', 'preferences', 'temporary', 'xdg']:
                (context / name).mkdir(mode=0o700)
            config = context / 'global.config'; config.write_text('')
            env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
            env.update(HOME=str(context / 'home'), CFFIXED_USER_HOME=str(context / 'preferences'),
                       XDG_CONFIG_HOME=str(context / 'xdg'), TMPDIR=str(context / 'temporary') + '/',
                       GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                       DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'),
                       TURTLEGIT_EDITOR_SAVE_HISTORY_CASE=case, TURTLEGIT_EDITOR_SAVE_HISTORY_LAYOUT=layout)
            approved = {str(git)}
            located = subprocess.run(['/usr/bin/xcrun', '--find', 'git'], capture_output=True, text=True)
            if located.returncode == 0:
                approved.add(str(Path(located.stdout.strip()).resolve()))
            helpers = root / 'build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers'
            if helpers.is_dir():
                approved.update(str(path.resolve()) for path in helpers.rglob('*') if path.is_file() and os.access(path, os.X_OK))
            row = dict(case=case, layout=layout, git=str(git), status='running')
            print('Checking editor Save/history ' + case + '/' + layout + ' with ' + str(git), flush=True)
            try:
                result = run_receiver([str(receiver), str(context / 'fixture'), str(git)], cwd=root, env=env,
                                      capture_output=True, text=True, timeout=300,
                                      timeout_sample=context / 'timeout.sample.txt')
                print(result.stdout, end=''); print(result.stderr, end='')
                row['exit_code'] = result.returncode
                result.check_returncode()
                if 'PASS: editor Save/history readiness ' + case not in result.stdout:
                    raise RuntimeError('Native receiver exited before completing its scope')
                row['status'] = 'passed'
            except BaseException as error:
                row.update(status='failed', error=str(error)); raise
            finally:
                sample = context / 'timeout.sample.txt'
                if sample.is_file():
                    shutil.copy2(sample, root / ('build/qa/editor-save-history-' + case + '-' + layout + '-' + str(index) + '-timeout.sample.txt'))
                try:
                    row['fallback_helper_cleanup'] = retire_owned_helpers(context, approved)
                    if row['status'] == 'passed' and row['fallback_helper_cleanup']:
                        row['status'] = 'failed-owned-helper-leak'
                        raise RuntimeError('Successful editor case left an owned helper running')
                except BaseException as cleanup_error:
                    row.update(status='failed-owned-cleanup', cleanup_error=str(cleanup_error))
                    raise
                finally:
                    results.append(row)
                    result_path.parent.mkdir(parents=True, exist_ok=True)
                    result_path.write_text(json.dumps(dict(cases=results), indent=2) + '\n')
                if row['status'] == 'failed-owned-helper-leak':
                    raise RuntimeError('Successful editor receiver left an owned helper running')
print('All selected editor Save/history cases passed', flush=True)
