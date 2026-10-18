#!/usr/bin/env python3
"""Grouped Stash preparation/completion and Submodule recovery workflows."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

CASES = {
    'stash': ('stash-operation-native-2026-10-18.swift', 'StashOperationVerification.verify()'),
    'stash-save': ('stash-save-progress-native-2026-10-08.swift', 'StashSaveProgressVerification.main()'),
    'stash-restore': ('stash-restore-native-2026-10-08.swift', 'StashRestoreVerification.main()'),
    'add-recovery': ('submodule-add-recovery-native-2026-10-18.swift', 'SubmoduleAddRecoveryVerification.verify()'),
    'update-recovery': ('submodule-update-recovery-native-2026-10-18.swift', 'SubmoduleUpdateRecoveryVerification.verify()'),
    'update-progress': ('submodule-update-progress-native-2026-10-09.swift', 'SubmoduleUpdateProgressReceiver.main()'),
    'sync': ('submodule-sync-native-2026-10-09.swift', 'SubmoduleSyncReceiver.main()'),
    'handoffs': ('submodule-handoffs-native-2026-10-14.swift', 'SubmoduleHandoffsVerification.main()'),
    'integration-entry': ('integration-commands-native-2026-10-18.swift', 'PrimaryCommandsVerification.verifyIntegration()'),
    'submodule-entry': ('submodule-commands-native-2026-10-18.swift', 'PrimaryCommandsVerification.verifySubmoduleCommands()'),
}

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=CASES, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-stash-submodule-') as temporary:
    folder = Path(temporary)
    fixtures = []
    for filename in dict.fromkeys(filename for filename, _ in CASES.values()):
        source = folder/filename
        source.write_text((root/'docs/qa'/filename).read_text().replace('@main ', '', 1))
        fixtures.append(source)
    # Reuse the retained command fixtures' shared assertions without compiling
    # unrelated command families into this receiver.
    primary = (root/'docs/qa/primary-commands-native-2026-10-18.swift').read_text()
    helper = folder/'PrimaryCommandsAssertions.swift'
    assertion_prefix = primary[:primary.index('    @MainActor static func verifyNetwork()')].replace('@main ', '', 1)
    single_assertion = next(line for line in primary.splitlines() if line.startswith('    static func requireOne'))
    helper.write_text(assertion_prefix + single_assertion + '\n}\n')
    fixtures.append(helper)
    main = folder/'StashSubmoduleMain.swift'
    cases = ''.join('case "'+case+'": try await '+kind+';' for case, (_, kind) in CASES.items())
    main.write_text('import AppKit\nimport ObjectiveC\nprivate extension NSWindow { @objc func turtleGitBatchOrder(_ place: NSWindow.OrderingMode, relativeTo number: Int) { alphaValue = 0; turtleGitBatchOrder(place, relativeTo: number) } }\n@main struct StashSubmoduleMain { @MainActor static func main() async throws { NSApplication.shared.setActivationPolicy(.prohibited); let original = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.order(_:relativeTo:)))!; let hidden = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.turtleGitBatchOrder(_:relativeTo:)))!; method_exchangeImplementations(original, hidden); defer { method_exchangeImplementations(original, hidden) }; switch ProcessInfo.processInfo.environment["TURTLEGIT_STASH_SUBMODULE_CASE"]! { '+cases+' default: fatalError("Unknown case") }; print("PASS: Stash/Submodule workflow completed") } }\n')
    receiver = build_receiver(root, fixtures+[main], folder)
    env = dict(os.environ, DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    env.pop('TURTLEGIT_REBASE_ACTION_CAPTURES', None)
    for key in ['GIT_CONFIG_PARAMETERS', 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_AUTHOR_DATE', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL', 'GIT_COMMITTER_DATE', 'TURTLEGIT_CREDENTIAL_CAPTURE', 'TURTLEGIT_SUBMODULE_SOURCE_CAPTURE']:
        env.pop(key, None)
    editor = root/'build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac'
    env['TURTLEGIT_REBASE_EDITOR'] = str(editor)
    for case in args.only or list(CASES):
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture = folder/(case+str(index)); fixture.mkdir()
            configuration = fixture/'global.config'; configuration.write_text('')
            env.update(GIT_CONFIG_GLOBAL=str(configuration), XDG_CONFIG_HOME=str(fixture/'xdg'))
            env['TURTLEGIT_STASH_SUBMODULE_CASE'] = case
            print('Checking Stash/Submodule '+case+' with '+str(git), flush=True)
            command = [str(receiver), str(fixture), str(git.absolute())]
            result = run_receiver(command, cwd=root, env=env, capture_output=True, text=True)
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if 'PASS: Stash/Submodule workflow completed' not in result.stdout:
                raise SystemExit('Operation workflow receiver exited before completion: '+case)
