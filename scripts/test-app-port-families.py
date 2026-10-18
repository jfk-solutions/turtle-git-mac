#!/usr/bin/env python3
"""Group the connected Commit visibility and Log source-command native workflows."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['commit', 'log'], action='append')
parser.add_argument('--captures', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-app-port-') as temporary:
    directory = Path(temporary)
    sources = []
    for name in ['commit-visibility-native-2026-10-18.swift', 'log-source-commands-native-2026-10-18.swift']:
        original = root/'docs/qa'/name
        source = directory/name
        source.write_text(original.read_text().replace('@main ', '', 1))
        sources.append(source)
    main = directory/'AppPortFamilyMain.swift'
    main.write_text('''import AppKit
@main struct AppPortFamilyMain {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        switch ProcessInfo.processInfo.environment["TURTLEGIT_APP_PORT_CASE"]! {
        case "commit": try await CommitVisibilityVerification.verify()
        case "log": try await LogSourceCommandsVerification.main()
        default: fatalError("Unknown app port family")
        }
        print("PASS: App port family case completed")
    }
}
''')
    receiver = build_receiver(root, sources+[main], directory)
    env = dict(os.environ, DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),
               GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for case in args.only or ['commit', 'log']:
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            folder = directory/(case+str(index)); folder.mkdir()
            env['TURTLEGIT_APP_PORT_CASE'] = case
            env.pop('TURTLEGIT_COMMIT_VISIBILITY_CAPTURE', None)
            if args.captures and case == 'commit' and index == 0:
                args.captures.mkdir(parents=True, exist_ok=True)
                env['TURTLEGIT_COMMIT_VISIBILITY_CAPTURE'] = str(args.captures.absolute())
            print('Checking '+case+' port family with '+str(git), flush=True)
            result = run_receiver([str(receiver), str(folder), str(git.absolute())],
                                  cwd=root, env=env, capture_output=True, text=True)
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if 'PASS: App port family case completed' not in result.stdout:
                raise SystemExit('App port family receiver exited before completion')
