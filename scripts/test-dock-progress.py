#!/usr/bin/env python3
"""Grouped native Dock, local command, replay and transport presentation acceptance."""
import argparse, os, tempfile
from pathlib import Path
from native_receiver import build_receiver, run_receiver
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['dock', 'local', 'replay', 'transport'], action='append')
parser.add_argument('--captures', type=Path)
args = parser.parse_args(); root = Path(__file__).resolve().parent.parent
cases = [('dock', 'dock-progress-native-2026-10-16.swift', 'PASS: native Dock'),
         ('local', 'local-command-progress-native-2026-10-14.swift', 'Local progress:'),
         ('replay', 'rebase-replay-progress-native-2026-10-14.swift', 'Replay progress:'),
         ('transport', 'transport-presentation-native-2026-10-15.swift', 'PASS: captured native activity')]
with tempfile.TemporaryDirectory(prefix='TurtleGitDock-') as temporary:
    directory = Path(temporary)
    environment = os.environ.copy()
    environment.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    editor = root/'build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac'
    for case, source, marker in cases:
        if args.only and case not in args.only: continue
        receiver = build_receiver(root, [root/'docs/qa'/source], directory)
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture = directory/(case+str(index)); fixture.mkdir(); case_environment = environment.copy()
            if args.captures and case == 'dock' and index == 0: case_environment['TURTLEGIT_DOCK_CAPTURES'] = str(args.captures.absolute())
            result = run_receiver([str(receiver), str(fixture), str(git.absolute()), str(editor)], cwd=root, env=case_environment, capture_output=True, text=True)
            print(result.stdout, end='', flush=True); print(result.stderr, end='', flush=True); result.check_returncode()
            if marker not in result.stdout: raise SystemExit('Receiver exited before final assertion: '+case)
