#!/usr/bin/env python3
"""Grouped Credential advanced editing and connected Merge operation workflows."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

CASES = {
    'credentials': ('credential-advanced-editing-native-2026-10-18.swift', 'CredentialAdvancedEditingVerification.verify()'),
    'credential-settings': ('credential-settings-native-2026-10-12.swift', 'CredentialSettingsVerification.verify()'),
    'credential-source': ('credential-source-family-native-2026-10-17.swift', 'CredentialSourceFamilyVerification.verify()'),
    'merge': ('merge-operation-native-2026-10-18.swift', 'MergeOperationVerification.verify()'),
    'merge-history': ('merge-history-native-2026-10-08.swift', 'MergeHistoryVerification.main()'),
    'merge-pickers': ('merge-pickers-native-2026-10-09.swift', 'MergePickerVerification.verify()'),
    'merge-progress': ('merge-progress-native-2026-10-08.swift', 'MergeProgressVerification.main()'),
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=CASES, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-credential-merge-') as temporary:
    folder = Path(temporary)
    fixtures = []
    for filename in dict.fromkeys(filename for filename, _ in CASES.values()):
        source = folder/filename
        source.write_text((root/'docs/qa'/filename).read_text().replace('@main ', '', 1))
        fixtures.append(source)
    main = folder/'CredentialMergeMain.swift'
    cases = ''.join('case "'+case+'": try await '+kind+';' for case, (_, kind) in CASES.items())
    main.write_text('import AppKit\n@main struct CredentialMergeMain { @MainActor static func main() async throws { NSApplication.shared.setActivationPolicy(.prohibited); switch ProcessInfo.processInfo.environment["TURTLEGIT_CREDENTIAL_MERGE_CASE"]! { '+cases+' default: fatalError("Unknown case") }; print("PASS: Credential/Merge workflow completed") } }\n')
    receiver = build_receiver(root, fixtures+[main], folder)
    env = dict(os.environ, DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    env.pop('TURTLEGIT_REBASE_ACTION_CAPTURES', None)
    for key in ['GIT_CONFIG_PARAMETERS', 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_AUTHOR_DATE', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL', 'GIT_COMMITTER_DATE', 'TURTLEGIT_CREDENTIAL_CAPTURE']:
        env.pop(key, None)
    editor = root/'build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac'
    env['TURTLEGIT_REBASE_EDITOR'] = str(editor)
    for case in args.only or list(CASES):
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture = folder/(case+str(index)); fixture.mkdir()
            configuration = fixture/'global.config'; configuration.write_text('')
            env.update(GIT_CONFIG_GLOBAL=str(configuration), XDG_CONFIG_HOME=str(fixture/'xdg'))
            env['TURTLEGIT_CREDENTIAL_MERGE_CASE'] = case
            print('Checking Credential/Merge '+case+' with '+str(git), flush=True)
            command = [str(receiver), str(fixture), str(git.absolute())]
            result = run_receiver(command, cwd=root, env=env, capture_output=True, text=True)
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if 'PASS: Credential/Merge workflow completed' not in result.stdout:
                raise SystemExit('Operation workflow receiver exited before completion: '+case)
