"""Cached private receivers for the connected Log/reference recovery checks."""
import argparse
import json
import os
from pathlib import Path
import shutil
import tempfile
from native_receiver import build_receiver, run_receiver

CASES = {
    'references': ('commit-containing-refs-native-2026-10-10.swift', 'CommitReferencesVerification.verify()'),
    'font': ('log-table-font-native-2026-10-08.swift', 'LogTableFontVerification.main()'),
    'rollup': ('log-rollup-native-2026-10-07.swift', 'RollupVerification.main()'),
}


def main(default_case=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--git', type=Path, action='append')
    parser.add_argument('--capture-dir', type=Path)
    parser.add_argument('--only', choices=CASES, action='append')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    generated = root / 'build/qa/history-recovery-native-sources'
    generated.mkdir(parents=True, exist_ok=True)
    fixtures = []
    for filename, _ in CASES.values():
        target = generated / filename
        target.write_text((root / 'docs/qa' / filename).read_text().replace('@main ', '', 1))
        fixtures.append(target)
    bootstrap = generated / 'HistoryRecoveryMain.swift'
    bootstrap.write_text(r'''import AppKit
import ObjectiveC
private extension NSWindow {
 @objc func turtleGitHistoryRecoveryOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;turtleGitHistoryRecoveryOrder(place,relativeTo:number)
 }
}
@main struct HistoryRecoveryMain {
 @MainActor static func drain() async throws {
  for _ in 0..<2000 {
   if CommitContainingReferencesWindowController.activeOperations==0 && LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeReferenceReads==0 && LogWindowModel.activeActionReads==0 && NSApp.windows.allSatisfy({!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}) {return}
   try await Task.sleep(nanoseconds:10_000_000)
  }
  throw NSError(domain:"History recovery retained owned work or windows",code:1)
 }
 @MainActor static func main() async throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let prefs=UserDefaults(suiteName:"TurtleGit.HistoryRecovery.Geometry")!
  DialogGeometry.install(preferences:prefs)
  defer{DialogGeometry.install(preferences:.standard);prefs.removePersistentDomain(forName:"TurtleGit.HistoryRecovery.Geometry")}
  let normal=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
  let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitHistoryRecoveryOrder(_:relativeTo:)))!
  method_exchangeImplementations(normal,hidden);defer{method_exchangeImplementations(normal,hidden)}
  do {
   switch ProcessInfo.processInfo.environment["TURTLEGIT_HISTORY_RECOVERY_CASE"]! {
''' + '\n'.join('case "' + case + '": try await ' + call for case, (_, call) in CASES.items()) + r'''
   default:fatalError("Unknown History recovery case")
   }
  } catch {
   NSApp.windows.forEach{$0.close()};try? await drain();throw error
  }
  NSApp.windows.forEach{$0.close()};try await drain()
  print("PASS: History recovery native case completed")
 }
}
''')
    receiver = build_receiver(root, fixtures + [bootstrap], generated)
    results = []
    for case in args.only or ([default_case] if default_case else list(CASES)):
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            git = git.resolve()
            if not git.is_file():
                parser.error('Git executable is missing: ' + str(git))
            with tempfile.TemporaryDirectory(prefix='turtlegit-history-recovery-' + case + '-') as temporary:
                context = Path(temporary).resolve()
                for name in ['fixture', 'preferences', 'home', 'temporary', 'xdg']:
                    (context / name).mkdir(mode=0o700)
                config = context / 'global.config'; config.write_text('')
                env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
                env.update(HOME=str(context / 'home'), CFFIXED_USER_HOME=str(context / 'preferences'),
                           XDG_CONFIG_HOME=str(context / 'xdg'), TMPDIR=str(context / 'temporary') + '/',
                           GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                           DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'),
                           TURTLEGIT_HISTORY_RECOVERY_CASE=case)
                command = [str(receiver), str(context / 'fixture'), str(git)]
                if args.capture_dir and case == 'references' and index == 0:
                    args.capture_dir.mkdir(parents=True, exist_ok=True)
                    command.append(str(args.capture_dir.resolve()))
                print('Checking History recovery ' + case + ' with ' + str(git), flush=True)
                try:
                    result = run_receiver(command, cwd=root, env=env, capture_output=True, text=True,
                                          timeout=300, timeout_sample=context / 'timeout.sample.txt')
                    print(result.stdout, end=''); print(result.stderr, end='')
                    passed = result.returncode == 0 and 'PASS: History recovery native case completed' in result.stdout
                    results.append(dict(case=case, git=str(git), returncode=result.returncode, passed=passed))
                    (root / 'build/qa/history-recovery-native-results.json').write_text(json.dumps(results, indent=2) + '\n')
                    result.check_returncode()
                    if not passed:
                        raise RuntimeError('History recovery receiver exited before completion: ' + case)
                finally:
                    sample = context / 'timeout.sample.txt'
                    if sample.is_file():
                        shutil.copy2(sample, root / ('build/qa/history-recovery-' + case + '-' + str(index) + '-timeout.sample.txt'))


if __name__ == '__main__':
    main()
