#!/usr/bin/env python3
"""Grouped durable paused replay actions and retained native replay workflows."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

CASES = {
    'linear': ('rebase-pending-actions-native-2026-10-18.swift', 'RebasePendingActionsVerification.verify(structural: false)'),
    'structural': ('rebase-pending-actions-native-2026-10-18.swift', 'RebasePendingActionsVerification.verify(structural: true)'),
    'menus': ('rebase-revision-menu-native-2026-10-18.swift', 'RebaseRevisionMenuVerification.verify()'),
    'controls': ('rebase-action-controls-native-2026-10-16.swift', 'RebaseActionControlsVerification.verify()'),
    'rows': ('rebase-row-drag-native-2026-10-13.swift', 'RebaseRowDragVerification.verify()'),
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=CASES, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-rebase-pending-actions-') as temporary:
    folder = Path(temporary)
    fixtures = []
    for filename in dict.fromkeys(filename for filename, _ in CASES.values()):
        source = folder/filename
        source.write_text((root/'docs/qa'/filename).read_text().replace('@main ', '', 1))
        fixtures.append(source)
    main = folder/'RebaseRevisionMain.swift'
    cases = ''.join('case "'+case+'": try await '+kind+';' for case, (_, kind) in CASES.items())
    main.write_text('import AppKit\n@main struct RebaseRevisionMain { @MainActor static func main() async throws { NSApplication.shared.setActivationPolicy(.prohibited); switch ProcessInfo.processInfo.environment["TURTLEGIT_REBASE_REVISION_CASE"]! { '+cases+' default: fatalError("Unknown case") }; print("PASS: Rebase revision family completed") } }\n')
    receiver = build_receiver(root, fixtures+[main], folder)
    env = dict(os.environ, DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    env.pop('TURTLEGIT_REBASE_ACTION_CAPTURES', None)
    editor = root/'build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac'
    env['TURTLEGIT_REBASE_EDITOR'] = str(editor)
    for case in args.only or ['linear', 'structural', 'menus', 'controls', 'rows']:
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture = folder/(case+str(index)); fixture.mkdir()
            env['TURTLEGIT_REBASE_REVISION_CASE'] = case
            print('Checking Rebase revision '+case+' with '+str(git), flush=True)
            result = run_receiver([str(receiver), str(fixture), str(git.absolute()), str(editor)], cwd=root, env=env, capture_output=True, text=True)
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if 'PASS: Rebase revision family completed' not in result.stdout:
                raise SystemExit('Rebase receiver exited before completion: '+case)
