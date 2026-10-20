#!/usr/bin/env python3
"""Grouped Commit identity repair, author controls, refresh and action ownership."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

cases = {
    'identity': ('commit-identity-native-2026-10-20.swift', 'CommitIdentityVerification.verify()'),
    'author': ('commit-author-field-native-2026-10-09.swift', 'CommitAuthorFieldVerification.verify()'),
    'focus': ('commit-branch-focus-native-2026-10-09.swift', 'CommitBranchFocusVerification.main()'),
    'refresh': ('commit-refresh-snapshot-native-2026-10-17.swift', 'CommitRefreshSnapshotVerification.verify()'),
    'actions': ('commit-last-action-native-2026-10-08.swift', 'CommitLastActionVerification.main()'),
    'columns': ('commit-column-sorting-native-2026-10-08.swift', 'CommitSortingVerification.main()'),
    'font': ('message-font-native-2026-10-08.swift', 'MessageFontVerification.main()'),
    'suggestions': ('message-suggestions-native-2026-10-15.swift', 'MessageSuggestionsVerification.verify()'),
    'metadata': ('commit-metadata-native-2026-10-09.swift', 'CommitMetadataVerification.verify()'),
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=cases, action='append')
parser.add_argument('--captures', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
selected = args.only or list(cases)
with tempfile.TemporaryDirectory(prefix='turtlegit-commit-preparation-') as temporary:
    directory = Path(temporary)
    sources = []
    for case in selected:
        name, _ = cases[case]
        source = directory / name
        source.write_text((root / 'docs/qa' / name).read_text().replace('@main ', '', 1))
        sources.append(source)
    main = directory / 'CommitPreparationMain.swift'
    main.write_text('import AppKit\n@main struct CommitPreparationMain { @MainActor static func main() async throws {\n'
                    'NSApp.setActivationPolicy(.prohibited)\n'
                    'switch ProcessInfo.processInfo.environment["TURTLEGIT_COMMIT_PREPARATION_CASE"]! {\n'
                    + ''.join('case "' + case + '": try await ' + cases[case][1] + '\n' for case in selected)
                    + 'default: fatalError("Unknown Commit preparation case")\n}\n'
                    'print("PASS: Commit preparation case completed")\n} }\n')
    receiver = build_receiver(root, sources + [main], directory)
    for case in selected:
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            context = directory / (case + str(index)); context.mkdir(mode=0o700)
            fixture = context / 'repository'; fixture.mkdir(mode=0o700)
            home = context / 'home'; home.mkdir(mode=0o700)
            config = context / 'global.config'; config.write_text('')
            private_tmp = context / 'temporary'; private_tmp.mkdir(mode=0o700)
            env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
            env.update(GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                       CFFIXED_USER_HOME=str(home), XDG_CONFIG_HOME=str(fixture / 'xdg'), TMPDIR=str(private_tmp),
                       DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'),
                       TURTLEGIT_COMMIT_PREPARATION_CASE=case)
            env.pop('TURTLEGIT_COMMIT_IDENTITY_CAPTURE_DIR', None)
            if args.captures and case == 'identity' and index == 0:
                env['TURTLEGIT_COMMIT_IDENTITY_CAPTURE_DIR'] = str(args.captures.absolute())
            print('Checking Commit preparation ' + case + ' with ' + str(git), flush=True)
            result = run_receiver([str(receiver), str(fixture), str(git.absolute())], cwd=root, env=env,
                                  capture_output=True, text=True, timeout_sample=fixture / 'timeout.sample.txt')
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if 'PASS: Commit preparation case completed' not in result.stdout:
                raise SystemExit('Receiver exited before completing Commit preparation: ' + case)
