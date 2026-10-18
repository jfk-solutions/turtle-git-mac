#!/usr/bin/env python3
"""Grouped source history/reference action and replay identity workflows."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

CASES = {
    'log': ('log-context-menu-policy-native-2026-10-18.swift', 'LogContextMenuPolicyVerification'),
    'references': ('reference-action-family-native-2026-10-18.swift', 'ReferenceActionFamilyVerification'),
    'blame': ('blame-history-policy-native-2026-10-18.swift', 'BlameHistoryPolicyVerification'),
    'replay': ('replay-hook-identity-native-2026-10-18.swift', 'ReplayHookIdentityVerification'),
    'remotes': ('remote-list-native-2026-10-18.swift', 'RemoteListVerification'),
    'remotes-retained': ('remote-settings-native-2026-10-09.swift', 'RemoteSettingsReceiver'),
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=CASES, action='append')
parser.add_argument('--captures', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-history-actions-') as temporary:
    directory = Path(temporary)
    main = directory/'HistoryActionMain.swift'
    cases = ''.join('case "'+case+'": try await '+kind+('.run();' if case == 'remotes-retained' else '.verify();') for case, (_, kind) in CASES.items())
    main.write_text('import AppKit\n@main struct HistoryActionMain { @MainActor static func main() async throws { NSApplication.shared.setActivationPolicy(.prohibited);switch ProcessInfo.processInfo.environment["TURTLEGIT_HISTORY_ACTION_CASE"]! { '+cases+' default: fatalError("Unknown case") }; print("PASS: History action case completed") } }\n')
    sources = []
    for filename, _ in CASES.values():
        source = directory/filename
        source.write_text((root/'docs/qa'/filename).read_text().replace('@main ', '', 1))
        sources.append(source)
    receiver = build_receiver(root, sources+[main], directory)
    env = dict(os.environ, DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for case in args.only or [name for name in CASES if name != 'remotes-retained']:
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            folder = directory/(case+str(index)); folder.mkdir()
            env['TURTLEGIT_HISTORY_ACTION_CASE'] = case
            env.pop('TURTLEGIT_REMOTE_LIST_CAPTURE', None)
            if args.captures and case == 'remotes' and index == 0:
                args.captures.mkdir(parents=True, exist_ok=True)
                env['TURTLEGIT_REMOTE_LIST_CAPTURE'] = str(args.captures.absolute())
            print('Checking history action '+case+' with '+str(git), flush=True)
            result = run_receiver([str(receiver), str(folder), str(git.absolute())], cwd=root, env=env, capture_output=True, text=True)
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if 'PASS: History action case completed' not in result.stdout:
                raise SystemExit('History action receiver exited before completion: '+case)
