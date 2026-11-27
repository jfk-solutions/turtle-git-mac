#!/usr/bin/env python3
"""Grouped Switch, Reset and Bisect review, execution and completion workflows."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

CASES = {
    'switch': ('switch-operation-native-2026-10-18.swift', 'try await SwitchOperationVerification.verify()'),
    'reset': ('reset-operation-native-2026-10-18.swift', 'try await ResetOperationVerification.verify()'),
    'bisect': ('bisect-operation-native-2026-10-18.swift', 'try await BisectOperationVerification.verify()'),
    'routing': ('operation-routing-native-2026-10-18.swift', 'try await OperationRoutingVerification.verify()'),
    'switch-progress': ('switch-progress-native-2026-10-08.swift', 'try await SwitchProgressVerification.main()'),
    'switch-pickers': ('switch-pickers-native-2026-10-09.swift', 'await SwitchPickerVerification.main()'),
    'reference-switch': ('reference-switch-native-2026-10-09.swift', 'await ReferenceSwitchVerification.main()'),
    'reflog-switch': ('reflog-express-switch-native-2026-10-08.swift', 'try await ReferenceLogExpressSwitchVerification.main()'),
    'reset-progress': ('reset-progress-native-2026-10-08.swift', 'try await ResetProgressVerification.main()'),
    'reset-picker': ('reset-picker-native-2026-10-09.swift', 'await ResetPickerVerification.main()'),
    'reset-workflow': ('reset-workflow-native-2026-10-15.swift', 'await ResetWorkflowVerification.main()'),
    'reset-modified': ('reset-modified-files-native-2026-10-09.swift', 'await ResetModifiedFilesVerification.main()'),
    'bisect-progress': ('bisect-progress-native-2026-10-14.swift', 'await BisectProgressVerification.main()'),
    'bisect-lifecycle': ('bisect-lifecycle-native-2026-10-13.swift', 'await BisectLifecycleVerification.main()'),
    'retained-bisect': ('cherry-pick-native-receiver-2026-10-06.swift', 'try await verifyNativeBisect(executable: URL(fileURLWithPath: CommandLine.arguments[2]))'),
}
# The hosted da754 step388 exhausted the unchanged 300s fixture compiler
# budget before any receiver ran. Keep each cohesive family in its own existing
# native_receiver cache entry; app objects/frameworks/toolchain remain shared.
FAMILIES = {
    'switch': ('switch', 'routing', 'switch-progress', 'switch-pickers', 'reference-switch', 'reflog-switch'),
    'reset': ('reset', 'reset-progress', 'reset-picker', 'reset-workflow', 'reset-modified'),
    'bisect': ('bisect', 'bisect-progress', 'bisect-lifecycle', 'retained-bisect'),
}


def family_for(case):
    return next(family for family, cases in FAMILIES.items() if case in cases)


def fixture_text(root, filename):
    text = (root/'docs/qa'/filename).read_text()
    if filename == 'cherry-pick-native-receiver-2026-10-06.swift':
        # Only these original independent helpers belong to retained Bisect.
        # Its mention of BisectOperationVerification is a comment, not a call.
        helper = text[text.index('@MainActor func findTable('):text.index('@MainActor func findRebaseProbe(')]
        body = text[text.index('@MainActor func verifyNativeBisect('):text.index('@MainActor func verify()')]
        body = body.replace('FileManager.default.temporaryDirectory.appendingPathComponent', 'URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent')
        text = 'import AppKit\nimport SwiftUI\nimport TurtleGitCore\n' + helper + body
    return text.replace('@main ', '', 1)


def build_family(root, family, folder, build):
    folder.mkdir()
    cases_in_family = [case for case in CASES if case in FAMILIES[family]]
    fixtures = []
    for filename in dict.fromkeys(CASES[case][0] for case in cases_in_family):
        source = folder/filename
        source.write_text(fixture_text(root, filename))
        fixtures.append(source)
    main = folder/'SwitchResetBisectMain.swift'
    cases = '\n'.join('case "'+case+'": '+CASES[case][1] for case in cases_in_family)
    main.write_text('''import AppKit
import ObjectiveC
private extension NSWindow {
    @objc func turtleGitOperationOrder(_ place: NSWindow.OrderingMode, relativeTo number: Int) {
        alphaValue = 0
        turtleGitOperationOrder(place, relativeTo: number)
    }
}
@main struct SwitchResetBisectMain {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.order(_:relativeTo:)))!
        let hidden = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.turtleGitOperationOrder(_:relativeTo:)))!
        method_exchangeImplementations(original, hidden)
        defer { method_exchangeImplementations(original, hidden) }
        switch ProcessInfo.processInfo.environment["TURTLEGIT_SWITCH_RESET_BISECT_CASE"]! {
''' + cases + '''
        default: fatalError("Unknown operation workflow")
        }
        print("PASS: Switch/Reset/Bisect workflow completed")
    }
}
''')
    print('Compiling Switch/Reset/Bisect family '+family+' ('+str(len(fixtures))+' fixtures)', flush=True)
    # No flags, timeout, fingerprint or ownership override: retain the complete
    # native_receiver app/fixture/framework/module/architecture/compiler closure.
    return build(root, fixtures+[main], folder)


def run_workflows(root, folder, selected, engines, *, build=build_receiver, run=run_receiver, environ=None):
    receivers = {}
    for family in dict.fromkeys(family_for(case) for case in selected):
        receivers[family] = build_family(root, family, folder/('family-'+family), build)
    env = dict(os.environ if environ is None else environ, DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for key in ['GIT_CONFIG_PARAMETERS', 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_AUTHOR_DATE', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL', 'GIT_COMMITTER_DATE', 'TURTLEGIT_REBASE_ACTION_CAPTURES', 'TURTLEGIT_SWITCH_SOURCE_CAPTURE']:
        env.pop(key, None)
    env['TURTLEGIT_REBASE_EDITOR'] = str(root/'build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac')
    # Keep the established case-outer/engine-inner runtime order, independent of
    # compilation partitioning. Each case still owns a separate private repo.
    for case in selected:
        for index, git in enumerate(engines):
            directory = folder/(case+str(index)); directory.mkdir()
            config = directory/'global.config'; config.write_text('')
            env.update(GIT_CONFIG_GLOBAL=str(config), XDG_CONFIG_HOME=str(directory/'xdg'), TURTLEGIT_SWITCH_RESET_BISECT_CASE=case)
            print('Checking Switch/Reset/Bisect '+case+' with '+str(git), flush=True)
            receiver = receivers[family_for(case)]
            result = run([str(receiver), str(directory), str(git.absolute())], cwd=root, env=env, capture_output=True, text=True)
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if 'PASS: Switch/Reset/Bisect workflow completed' not in result.stdout:
                raise SystemExit('Operation receiver exited before completion: '+case)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--git', type=Path, action='append')
    parser.add_argument('--only', choices=CASES, action='append')
    args = parser.parse_args(argv)
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix='turtlegit-switch-reset-bisect-') as temporary:
        run_workflows(root, Path(temporary), args.only or list(CASES), args.git or [Path('/usr/bin/git')])
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
