#!/usr/bin/env python3
"""Build once, then check captured reference menus and retained related workflows."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

CASES = {
    'presentation': ('reference-presentation-native-2026-10-16.swift', 'ReferencePresentationVerification'),
    'targets': ('reference-menu-targets-native-2026-10-16.swift', 'ReferenceMenuTargetsVerification'),
    'folders': ('reference-folders-native-2026-10-09.swift', 'ReferenceFolderVerification'),
    'comparison': ('reference-comparison-native-2026-10-09.swift', 'ReferenceComparisonVerification'),
    'tracking': ('reference-tracking-native-2026-10-09.swift', 'ReferenceTrackingVerification'),
    'rename': ('reference-rename-native-2026-10-09.swift', 'ReferenceRenameVerification'),
    'standalone': ('reference-standalone-native-2026-10-09.swift', 'StandaloneReferenceVerification'),
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=CASES, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='TurtleGitReferenceTargets-') as temporary:
    directory = Path(temporary)
    inputs = root / 'build/qa/reference-menu-target-fixtures'
    inputs.mkdir(parents=True, exist_ok=True)
    sources = []
    for name, (filename, _) in CASES.items():
        path = inputs / filename
        path.write_text((root / 'docs/qa' / filename).read_text().replace('@main ', '', 1))
        sources.append(path)
    main = inputs / 'ReferenceTargetsMain.swift'
    cases = ''.join('case "' + name + '": try await ' + receiver + '.verify();' for name, (_, receiver) in CASES.items())
    main.write_text('import AppKit\n@main struct ReferenceTargetsMain { @MainActor static func main() async throws { NSApplication.shared.setActivationPolicy(.prohibited); switch ProcessInfo.processInfo.environment["TURTLEGIT_REFERENCE_CASE"] { ' + cases + ' default: fatalError("Unknown case") }; print("PASS: grouped reference menu case") } }\n')
    receiver = build_receiver(root, sources + [main], directory)
    env = os.environ.copy()
    env.update(DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
        for case in args.only or CASES:
            fixture = directory / (str(index) + '-' + case)
            fixture.mkdir()
            env['TURTLEGIT_REFERENCE_CASE'] = case
            print('Checking reference ' + case + ' with ' + str(git), flush=True)
            result = run_receiver([str(receiver), str(fixture), str(git.absolute()), case], cwd=root, env=env, capture_output=True, text=True)
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if 'PASS: grouped reference menu case' not in result.stdout:
                raise SystemExit('Receiver exited before final assertions.')
