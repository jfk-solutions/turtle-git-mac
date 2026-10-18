#!/usr/bin/env python3
"""Grouped history reference actions and owned native comparison workflows."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

CASES = {
    'rebase': ('rebase-reference-context-native-2026-10-18.swift', 'RebaseReferenceContextVerification.verify()'),
    'references': ('reference-comparison-ownership-native-2026-10-18.swift', 'ReferenceComparisonOwnershipVerification.verify()'),
    'blame': ('blame-parent-action-native-2026-10-18.swift', 'BlameParentActionVerification.verify()'),
    'rebase-tools': ('rebase-history-tools-native-2026-10-18.swift', 'RebaseHistoryToolsVerification.verify()'),
    'blame-source': ('blame-source-menu-native-2026-10-16.swift', 'BlameSourceMenuVerification.verify()'),
    'reference-actions': ('reference-action-family-native-2026-10-18.swift', 'ReferenceActionFamilyVerification.verify()'),
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=CASES, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-history-reference-workflows-') as temporary:
    folder = Path(temporary)
    fixtures = []
    for filename in dict.fromkeys(filename for filename, _ in CASES.values()):
        source = folder/filename
        source.write_text((root/'docs/qa'/filename).read_text().replace('@main ', '', 1))
        fixtures.append(source)
    main = folder/'HistoryReferenceMain.swift'
    cases = ''.join('case "'+case+'": try await '+kind+';' for case, (_, kind) in CASES.items())
    main.write_text('import AppKit\n@main struct HistoryReferenceMain { @MainActor static func main() async throws { NSApplication.shared.setActivationPolicy(.prohibited); switch ProcessInfo.processInfo.environment["TURTLEGIT_HISTORY_REFERENCE_CASE"]! { '+cases+' default: fatalError("Unknown case") }; print("PASS: History/reference workflow completed") } }\n')
    receiver = build_receiver(root, fixtures+[main], folder)
    env = dict(os.environ, DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    env.pop('TURTLEGIT_REBASE_ACTION_CAPTURES', None)
    editor = root/'build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac'
    env['TURTLEGIT_REBASE_EDITOR'] = str(editor)
    for case in args.only or list(CASES):
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture = folder/(case+str(index)); fixture.mkdir()
            env['TURTLEGIT_HISTORY_REFERENCE_CASE'] = case
            print('Checking history/reference '+case+' with '+str(git), flush=True)
            command = [str(receiver), str(fixture), str(git.absolute())]
            result = run_receiver(command, cwd=root, env=env, capture_output=True, text=True)
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if 'PASS: History/reference workflow completed' not in result.stdout:
                raise SystemExit('History/reference receiver exited before completion: '+case)
