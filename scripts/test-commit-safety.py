#!/usr/bin/env python3
"""Grouped Commit detached-HEAD safety and cancelled issue-draft recovery."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

cases = {
    'detached': ('commit-detached-native-2026-10-20.swift', 'CommitDetachedVerification.detached()'),
    'history': ('commit-detached-native-2026-10-20.swift', 'CommitDetachedVerification.history()'),
    'actions': ('commit-last-action-native-2026-10-08.swift', 'CommitLastActionVerification.main()'),
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=cases, action='append')
parser.add_argument('--captures', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
selected = args.only or list(cases)
with tempfile.TemporaryDirectory(prefix='turtlegit-commit-safety-') as temporary:
    directory = Path(temporary)
    sources = []
    for name in dict.fromkeys(cases[case][0] for case in selected):
        source = directory / name
        source.write_text((root / 'docs/qa' / name).read_text().replace('@main ', '', 1))
        sources.append(source)
    main = directory / 'CommitSafetyMain.swift'
    main.write_text('import AppKit\n@main struct CommitSafetyMain { @MainActor static func main() async throws {\n'
                    'NSApp.setActivationPolicy(.prohibited)\n'
                    'switch ProcessInfo.processInfo.environment["TURTLEGIT_COMMIT_SAFETY_CASE"]! {\n'
                    + ''.join('case "' + case + '": try await ' + cases[case][1] + '\n' for case in selected)
                    + 'default: fatalError("Unknown Commit safety case")\n}\n'
                    'print("PASS: Commit safety case completed")\n} }\n')
    receiver = build_receiver(root, sources + [main], directory)
    for case in selected:
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            context = directory / (case + str(index)); context.mkdir(mode=0o700)
            fixture = context / 'repository'; fixture.mkdir(mode=0o700)
            home = context / 'home'; home.mkdir(mode=0o700)
            xdg = context / 'xdg'; xdg.mkdir(mode=0o700)
            config = context / 'global.config'; config.write_text('')
            private_tmp = context / 'temporary'; private_tmp.mkdir(mode=0o700)
            env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
            env.update(GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                       CFFIXED_USER_HOME=str(home), XDG_CONFIG_HOME=str(xdg), TMPDIR=str(private_tmp),
                       DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'),
                       TURTLEGIT_COMMIT_SAFETY_CASE=case)
            env.pop('TURTLEGIT_COMMIT_SAFETY_CAPTURE_DIR', None)
            if args.captures and case == 'detached' and index == 0:
                env['TURTLEGIT_COMMIT_SAFETY_CAPTURE_DIR'] = str(args.captures.absolute())
            print('Checking Commit safety ' + case + ' with ' + str(git), flush=True)
            result = run_receiver([str(receiver), str(fixture), str(git.absolute())], cwd=root, env=env,
                                  capture_output=True, text=True, timeout_sample=context / 'timeout.sample.txt')
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if 'PASS: Commit safety case completed' not in result.stdout:
                raise SystemExit('Receiver exited before completing Commit safety: ' + case)
