#!/usr/bin/env python3
"""Grouped native block selection/navigation, whitespace and retained editor workflows."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--only',action='append',choices=['initial','history','clipboard','block-selection','navigation','whitespace','one-pane'])
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-whitespace-states-') as temporary:
    folder=Path(temporary);inputs=root/'build/qa/merge-whitespace-states-fixtures';inputs.mkdir(parents=True,exist_ok=True)
    sources=[]
    for name in ['merge-initial-navigation-native-2026-10-15.swift','merge-editor-history-native-2026-10-15.swift','merge-clipboard-native-2026-10-13.swift','merge-block-selection-native-2026-10-15.swift','three-pane-engine-native-2026-10-12.swift','merge-block-navigation-native-2026-10-15.swift','merge-whitespace-states-native-2026-10-15.swift','merge-one-pane-native-2026-10-12.swift','two-pane-engine-native-2026-10-12.swift']:
        path=inputs/name;path.write_text((root/'docs/qa'/name).read_text().replace('@main ', '',1));sources.append(path)
    main=inputs/'WhitespaceStatesMain.swift'
    cases=[('initial','MergeInitialNavigationVerification.verify()'),('history','MergeEditorHistoryVerification.verify()'),('clipboard','MergeClipboardVerification.verify()'),('block-selection','MergeBlockSelectionVerification.verify()'),('navigation','MergeBlockNavigationVerification.verify()'),('whitespace','MergeWhitespaceStatesVerification.verify()'),('one-pane','MergeOnePaneNativeVerification.verify()')]
    calls=' '.join('try await '+call+';' for name,call in cases if not args.only or name in args.only)
    main.write_text('import AppKit\n@main struct WhitespaceStatesMain { @MainActor static func main() async throws { NSApplication.shared.setActivationPolicy(.prohibited); '+calls+' print("PASS: grouped native editor workflows") } }\n')
    print('Checking native editor cases: '+', '.join(name for name,call in cases if not args.only or name in args.only),flush=True)
    receiver=build_receiver(root,sources+[main],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    result=run_receiver([str(receiver),str(folder),'/usr/bin/git'],cwd=root,env=env,capture_output=True,text=True)
    print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
    if 'PASS: grouped native editor workflows' not in result.stdout:raise SystemExit('Receiver exited before final assertions.')
