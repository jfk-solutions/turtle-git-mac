#!/usr/bin/env python3
"""Grouped Commit restoration, attempted-message recovery and ReCommit editor lifetime."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

cases = {name: 'CommitResultVerification.' + name + '()' for name in ['restoration', 'failure', 'editor', 'lifetime']}
cases['format'] = 'MessageFileVerification.main()'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=cases, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-commit-result-') as temporary:
    directory = Path(temporary)
    selected = args.only or list(cases)
    sources = [root / 'docs/qa/commit-result-lifecycle-native-2026-10-20.swift']
    if 'format' in selected:
        formatted = directory / 'commit-message-file-native-2026-10-07.swift'
        formatted.write_text((root / 'docs/qa' / formatted.name).read_text().replace('@main ', '', 1))
        sources.append(formatted)
    main = directory / 'CommitResultMain.swift'
    main.write_text('import AppKit\n@main struct CommitResultMain { @MainActor static func main() async throws {\n'
                    'NSApp.setActivationPolicy(.prohibited)\n'
                    'switch ProcessInfo.processInfo.environment["TURTLEGIT_COMMIT_RESULT_CASE"]! {\n'
                    + ''.join('case "' + case + '": try await ' + cases[case] + '\n' for case in selected)
                    + 'default: fatalError("Unknown Commit result case")\n}\n'
                    'print("PASS: Commit result case completed")\n} }\n')
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
                       TURTLEGIT_COMMIT_RESULT_CASE=case)
            print('Checking Commit result ' + case + ' with ' + str(git), flush=True)
            result = run_receiver([str(receiver), str(fixture), str(git.absolute())], cwd=root, env=env,
                                  capture_output=True, text=True, timeout_sample=context / 'timeout.sample.txt')
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if 'PASS: Commit result case completed' not in result.stdout:
                raise SystemExit('Receiver exited before completing Commit result: ' + case)
