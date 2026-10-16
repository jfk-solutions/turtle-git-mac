#!/usr/bin/env python3
"""Grouped private-agent recovery, transport coordination and saved credential checks."""
import argparse
import os
import tempfile
from pathlib import Path

from native_receiver import build_receiver, run_receiver

CASES = {
    'lifecycle': ('ssh-session-lifecycle-native-2026-10-16.swift', 'SSHSessionLifecycleVerification.verify()'),
    'coordinator': ('ssh-coordinator-native-2026-10-09.swift', 'SSHCoordinatorLifecycle.run()'),
    'authentication': ('ssh-authentication-native-2026-10-13.swift', 'SSHAuthenticationVerification.run()'),
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--only', choices=CASES, action='append')
parser.add_argument('--git', type=Path, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
selected = list(dict.fromkeys(args.only or CASES))
# Stable generated source locations let native_receiver reuse unchanged fixtures.
fixtures = root / 'build/qa/ssh-lifecycle-fixtures'
fixtures.mkdir(parents=True, exist_ok=True)
sources = []
for case in selected:
    name, _ = CASES[case]
    source = fixtures / name
    source.write_text((root / 'docs/qa' / name).read_text().replace('@main ', '', 1))
    sources.append(source)
if 'coordinator' in selected:
    cleanup = fixtures / 'CoordinatorLifecycle.swift'
    cleanup.write_text('''import AppKit
struct SSHCoordinatorLifecycle {
    @MainActor static func run() async throws {
        do { try await SSHCoordinatorReceiver.run() }
        catch { try? await SSHCoordinatorReceiver.cleanupAddModels(); throw error }
        try await SSHCoordinatorReceiver.cleanupAddModels()
    }
}
''')
    sources.append(cleanup)
main = fixtures / 'SSHMain.swift'
main.write_text('''import AppKit
@main struct SSHMain {
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        switch ProcessInfo.processInfo.environment["TURTLEGIT_SSH_CASE"]! {
''' + ''.join('case "' + case + '": try await ' + CASES[case][1] + '\n' for case in selected) + '''
        default: fatalError("Unknown SSH case")
        }
        print("PASS: SSH lifecycle family case completed")
    }
}
''')
with tempfile.TemporaryDirectory(prefix='tg-ss-') as temporary:
    directory = Path(temporary)
    binary = build_receiver(root, sources + [main], directory)
    env = os.environ.copy()
    env.update(DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'),
               GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    helper = root / 'build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/SSHAskpass/TurtleGitSSHAskpass'
    for case in selected:
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture = directory / (case[0] + str(index))
            fixture.mkdir()
            env['TURTLEGIT_SSH_CASE'] = case
            print('Checking SSH ' + case + ' with ' + str(git), flush=True)
            result = run_receiver([str(binary), str(fixture), str(git.absolute()), str(helper)],
                                  cwd=root, env=env, capture_output=True, text=True)
            print(result.stdout, end='')
            print(result.stderr, end='')
            result.check_returncode()
            if 'PASS: SSH lifecycle family case completed' not in result.stdout:
                raise SystemExit('SSH receiver exited without completion')
