#!/usr/bin/env python3
"""Grouped Commit, Rebase message editing and Fetch/Pull completion workflows."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

CASES = {
    'commit': ('commit-option-transition-native-2026-10-18.swift', 'CommitOptionTransitionVerification.verify()'),
    'rebase': ('rebase-message-edit-native-2026-10-18.swift', 'RebaseMessageEditVerification.verify()'),
    'transport': ('fetch-pull-handoff-native-2026-10-18.swift', 'FetchPullHandoffVerification.verify()'),
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=CASES, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-operation-workflows-') as temporary:
    folder = Path(temporary)
    fixtures = []
    for filename in dict.fromkeys(filename for filename, _ in CASES.values()):
        source = folder/filename
        source.write_text((root/'docs/qa'/filename).read_text().replace('@main ', '', 1))
        fixtures.append(source)
    main = folder/'OperationWorkflowMain.swift'
    cases = ''.join('case "'+case+'": try await '+kind+';' for case, (_, kind) in CASES.items())
    main.write_text('import AppKit\n@main struct OperationWorkflowMain { @MainActor static func main() async throws { NSApplication.shared.setActivationPolicy(.prohibited); switch ProcessInfo.processInfo.environment["TURTLEGIT_OPERATION_WORKFLOW_CASE"]! { '+cases+' default: fatalError("Unknown case") }; print("PASS: Operation workflow completed") } }\n')
    receiver = build_receiver(root, fixtures+[main], folder)
    env = dict(os.environ, DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    env.pop('TURTLEGIT_REBASE_ACTION_CAPTURES', None)
    editor = root/'build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac'
    env['TURTLEGIT_REBASE_EDITOR'] = str(editor)
    for case in args.only or list(CASES):
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture = folder/(case+str(index)); fixture.mkdir()
            env['TURTLEGIT_OPERATION_WORKFLOW_CASE'] = case
            print('Checking operation workflow '+case+' with '+str(git), flush=True)
            command = [str(receiver), str(fixture), str(git.absolute())]
            result = run_receiver(command, cwd=root, env=env, capture_output=True, text=True)
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if 'PASS: Operation workflow completed' not in result.stdout:
                raise SystemExit('Operation workflow receiver exited before completion: '+case)
