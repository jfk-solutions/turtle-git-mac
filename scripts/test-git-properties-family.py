#!/usr/bin/env python3
"""Grouped Git Properties values, writes, live parent pages and ownership checks."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['properties', 'parents'], action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-properties-family-') as temporary:
    folder = Path(temporary)
    inputs = root / 'build/qa/git-properties-fixtures'
    inputs.mkdir(parents=True, exist_ok=True)
    fixtures = []
    for name in ['git-properties-native-2026-10-13.swift', 'git-properties-parents-native-2026-10-15.swift']:
        helper = inputs / name
        helper.write_text((root / 'docs/qa' / name).read_text().replace('@main ', '', 1))
        fixtures.append(helper)
    main = inputs / 'GitPropertiesMain.swift'
    main.write_text('import AppKit\n@main struct GitPropertiesMain { @MainActor static func main() async throws { switch ProcessInfo.processInfo.environment["TURTLEGIT_PROPERTIES_CASE"]! {\ncase "properties": try await GitPropertiesVerification.verify()\ncase "parents": try await GitPropertiesParentsVerification.verify()\ndefault: fatalError("Unknown property case")\n}; print("PASS: Git Properties case completed") } }\n')
    receiver = build_receiver(root, fixtures + [main], folder)
    env = os.environ.copy()
    env.update(DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
    for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
        for case in args.only or ['properties', 'parents']:
            fixture = folder / (str(index) + '-' + case)
            fixture.mkdir()
            env['TURTLEGIT_PROPERTIES_CASE'] = case
            print('Checking ' + case + ' with ' + str(git), flush=True)
            result = run_receiver([str(receiver), str(fixture), str(git.absolute())], cwd=root, env=env, capture_output=True, text=True)
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if 'PASS: Git Properties case completed' not in result.stdout:
                raise SystemExit('Properties receiver exited before completion.')
