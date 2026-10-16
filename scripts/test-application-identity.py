#!/usr/bin/env python3
"""Grouped application/document identity, file-open and retained document/Dock acceptance."""
import argparse, os, tempfile
from pathlib import Path
from native_receiver import build_receiver, run_receiver
from validate_application_identity import validate
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['identity', 'document', 'dock'], action='append')
parser.add_argument('--captures', type=Path)
args = parser.parse_args(); root = Path(__file__).resolve().parent.parent
app = root/'build/Build/Products/Debug/TurtleGitMac.app'; validate(app)
cases = [('identity', 'application-identity-native-2026-10-16.swift', 'PASS: native file-URL'), ('document', 'unified-document-native-2026-10-15.swift', 'PASS: Unified document native'), ('dock', 'dock-progress-native-2026-10-16.swift', 'PASS: native Dock')]
with tempfile.TemporaryDirectory(prefix='TurtleGitIdentity-') as temporary:
    directory = Path(temporary); env = os.environ.copy(); env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for case, source, marker in cases:
        if args.only and case not in args.only: continue
        receiver = build_receiver(root, [root/'docs/qa'/source], directory)
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture = directory/(case+str(index)); fixture.mkdir(); case_env = env.copy()
            if args.captures and case == 'dock' and index == 0: case_env['TURTLEGIT_DOCK_CAPTURES'] = str(args.captures.absolute())
            result = run_receiver([str(receiver), str(fixture), str(git.absolute()), str(app/'Contents/MacOS/TurtleGitMac')], cwd=root, env=case_env, capture_output=True, text=True)
            print(result.stdout, end='', flush=True); print(result.stderr, end='', flush=True); result.check_returncode()
            if marker not in result.stdout: raise SystemExit('Receiver exited before final assertion: '+case)
