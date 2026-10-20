#!/usr/bin/env python3
"""Grouped native Edit Notes identity, retry, cancellation and captured-target lifecycle."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

cases = ['identity', 'retry', 'cancellation', 'ownership', 'target']
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=cases, action='append')
parser.add_argument('--capture-dir', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-note-lifecycle-') as temporary:
    directory = Path(temporary)
    selected = args.only or cases
    main = directory / 'CommitNoteLifecycleMain.swift'
    main.write_text('import AppKit\n@main struct CommitNoteLifecycleMain { @MainActor static func main() async throws {\n'
                    'NSApp.setActivationPolicy(.prohibited)\n'
                    'switch ProcessInfo.processInfo.environment["TURTLEGIT_NOTE_LIFECYCLE_CASE"]! {\n'
                    + ''.join('case "' + case + '": try await CommitNoteLifecycleVerification.' + case + '()\n' for case in selected)
                    + 'default: fatalError("Unknown Edit Notes case")\n}\n'
                    'print("PASS: Edit Notes lifecycle case completed")\n} }\n')
    receiver = build_receiver(root, [root / 'docs/qa/commit-note-lifecycle-native-2026-10-20.swift', main], directory)
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
                       TURTLEGIT_NOTE_LIFECYCLE_CASE=case)
            if args.capture_dir and index == 0:
                args.capture_dir.mkdir(parents=True, exist_ok=True)
                env['TURTLEGIT_NOTE_CAPTURE_DIR'] = str(args.capture_dir.resolve())
            print('Checking Edit Notes ' + case + ' with ' + str(git), flush=True)
            result = run_receiver([str(receiver), str(fixture), str(git.absolute())], cwd=root, env=env,
                                  capture_output=True, text=True, timeout_sample=context / 'timeout.sample.txt')
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if 'PASS: Edit Notes lifecycle case completed' not in result.stdout:
                raise SystemExit('Receiver exited before completing Edit Notes: ' + case)
