#!/usr/bin/env python3
"""One grouped inline UI checkpoint against current Debug app objects."""
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver
root = Path(__file__).resolve().parent.parent
snapshot = root / 'build/qa/inline-source-expected.json'
if not snapshot.exists():
    raise SystemExit('Run scripts/test-inline-source.py before the native source comparison.')
with tempfile.TemporaryDirectory(prefix='turtlegit-inline-native-') as temporary:
    folder = Path(temporary)
    fixtures = []
    for name in ['two-pane-engine-native-2026-10-12.swift', 'three-pane-engine-native-2026-10-12.swift']:
        original = root / 'docs/qa' / name
        # Retain existing helper implementations without executing unrelated suites.
        helper = folder / name; helper.write_text(original.read_text().replace('@main ', '', 1)); fixtures.append(helper)
    fixtures += [root / 'docs/qa/merge-inline-native-2026-10-14.swift', root / 'docs/qa/inline-engine-native-2026-10-15.swift']
    receiver = build_receiver(root, fixtures, folder)
    env = os.environ.copy(); env.update(TURTLEGIT_INLINE_SOURCE_EXPECTED=str(snapshot), DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
    result = run_receiver([str(receiver), '--no-capture'], cwd=root, env=env, capture_output=True, text=True)
    print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
    if 'PASS: inline engine completed:' not in result.stdout:
        raise SystemExit('Inline receiver exited before its completion marker.')
