#!/usr/bin/env python3
"""Grouped Log integration and Rebase selector check against current Debug app objects."""
import argparse, os, tempfile
from pathlib import Path
from native_receiver import build_receiver, run_receiver
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
cases = [
    ('log-canonical-integration-native-2026-10-16.swift', 'PASS: canonical Log'),
    ('log-integration-preparation-native-2026-10-16.swift', 'PASS: source first-reference Merge'),
    ('rebase-references-native-2026-10-14.swift', 'Rebase references: source dropdown'),
]
with tempfile.TemporaryDirectory(prefix='tg-canonical-integration-') as temporary:
    directory = Path(temporary)
    env = os.environ.copy()
    env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for case, marker in cases:
        receiver = build_receiver(root, [root/'docs/qa'/case], directory)
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture = directory/(case + str(index)); fixture.mkdir()
            result = run_receiver([str(receiver),str(fixture),str(git.absolute())], cwd=root, env=env, capture_output=True, text=True)
            print(result.stdout,end=''); print(result.stderr,end=''); result.check_returncode()
            if marker not in result.stdout: raise SystemExit('Receiver exited before final assertion: ' + case)
