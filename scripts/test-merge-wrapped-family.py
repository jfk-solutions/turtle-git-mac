#!/usr/bin/env python3
"""Grouped moved blocks, wrapped geometry/navigation and retained editor owners; one cached link."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver
parser=argparse.ArgumentParser(description=__doc__)
cases={'ownership':'MergeViewportOwnershipVerification','terminal':'MergeTerminalRecordVerification','margin-selection':'MergeMarginSelectionVerification','margin':'MergeMarginVerification','moved':'MergeMovedBlocksVerification','wrapped':'MergeWrappedNavigationVerification','wrapping':'MergeWrappingVerification','navigation':'MergeBlockNavigationVerification','three-pane':'MergeThreePaneNavigationVerification','initial':'MergeInitialNavigationVerification','folding':'MergeFoldingNativeVerification','find':'MergeFindNativeVerification'}
parser.add_argument('--only',choices=cases,action='append')
parser.add_argument('--captures',type=Path)
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-wrapped-editors-') as temporary:
    folder=Path(temporary);inputs=root/'build/qa/merge-wrapped-fixtures';inputs.mkdir(parents=True,exist_ok=True)
    sources=[]
    for name in ['merge-viewport-ownership-native-2026-10-17.swift','merge-terminal-record-native-2026-10-16.swift','merge-margin-selection-native-2026-10-16.swift','merge-margin-native-2026-10-16.swift','two-pane-engine-native-2026-10-12.swift','three-pane-engine-native-2026-10-12.swift','merge-wrapped-navigation-native-2026-10-16.swift','merge-moved-blocks-native-2026-10-16.swift','merge-wrapping-native-2026-10-12.swift','merge-block-navigation-native-2026-10-15.swift','merge-three-pane-navigation-native-2026-10-15.swift','merge-initial-navigation-native-2026-10-15.swift','merge-folding-native-2026-10-14.swift','merge-find-native-2026-10-12.swift']:
        source=inputs/name;source.write_text((root/'docs/qa'/name).read_text().replace('@main ', '',1));sources.append(source)
    main=inputs/'WrappedMain.swift'
    main.write_text('import AppKit\n@main struct WrappedMain { @MainActor static func main() async throws { NSApplication.shared.setActivationPolicy(ProcessInfo.processInfo.environment["TURTLEGIT_WRAP_CAPTURE"] == nil ? .prohibited : .accessory); switch ProcessInfo.processInfo.environment["TURTLEGIT_WRAP_CASE"]! {\n'+''.join('case "'+name+'": try await '+kind+'.verify()\n' for name,kind in cases.items())+'default: fatalError("Unknown wrapped editor case")\n}; print("PASS: wrapped editor case completed") } }\n')
    receiver=build_receiver(root,sources+[main],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for case in args.only or cases:
        env['TURTLEGIT_WRAP_CASE']=case;env.pop('TURTLEGIT_WRAP_CAPTURE',None)
        if args.captures and case in ['terminal','margin-selection','margin','wrapped','moved']:
            args.captures.mkdir(parents=True,exist_ok=True);env['TURTLEGIT_WRAP_CAPTURE']=str(args.captures.absolute())
        print('Checking wrapped editor '+case,flush=True)
        result=run_receiver([str(receiver)],cwd=root,env=env,capture_output=True,text=True)
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if 'PASS: wrapped editor case completed' not in result.stdout:raise SystemExit('Wrapped editor receiver exited before completion.')
