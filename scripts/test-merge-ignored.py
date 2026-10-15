#!/usr/bin/env python3
"""Grouped current-object ignored-conflict workflow and retained merge history."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--only',choices=['workflow','retained','blocks','aligned'],action='append')
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-merge-ignored-') as temporary:
    folder=Path(temporary)
    inputs=root/'build/qa/merge-ignored-fixtures';inputs.mkdir(parents=True,exist_ok=True)
    fixtures=[]
    for name in ['merge-aligned-rows-native-2026-10-16.swift','merge-source-blocks-native-2026-10-16.swift','merge-three-pane-navigation-native-2026-10-15.swift','merge-ignored-native-2026-10-15.swift','three-pane-engine-native-2026-10-12.swift','merge-result-colors-native-2026-10-14.swift']:
        path=inputs/name;path.write_text((root/'docs/qa'/name).read_text().replace('@main ', '',1));fixtures.append(path)
    main=inputs/'MergeIgnoredMain.swift'
    main.write_text('import AppKit\n@main struct MergeIgnoredMain { @MainActor static func main() async throws { NSApplication.shared.setActivationPolicy(.prohibited); if ProcessInfo.processInfo.environment["TURTLEGIT_MERGE_IGNORED_CASE"] == "aligned" { try await MergeAlignedRowsVerification.verify(); print("PASS: aligned result rows") } else if ProcessInfo.processInfo.environment["TURTLEGIT_MERGE_IGNORED_CASE"] == "blocks" { try await MergeSourceBlocksVerification.verify(); print("PASS: source block workflow") } else if ProcessInfo.processInfo.environment["TURTLEGIT_MERGE_IGNORED_CASE"] == "retained" { try await MergeThreePaneNavigationVerification.verify(); try await ThreePaneEngineVerification.verify(configuration: .bundled()); try await MergeResultColorsVerification.verify(); print("PASS: retained merge engine and result history") } else { try await MergeIgnoredVerification.main() } } }\n')
    receiver=build_receiver(root,fixtures+[main],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    cases=[]
    engines=args.git or [Path('/usr/bin/git')]
    if not args.only or 'workflow' in args.only:cases += [('workflow',git) for git in engines]
    if not args.only or 'retained' in args.only:cases.append(('retained',engines[0]))
    if not args.only or 'blocks' in args.only:cases.append(('blocks',engines[0]))
    if not args.only or 'aligned' in args.only:cases.append(('aligned',engines[0]))
    for index,(case,git) in enumerate(cases):
        fixture=folder/str(index);fixture.mkdir();env['TURTLEGIT_MERGE_IGNORED_CASE']=case
        print('Checking ignored merge '+case+' with '+str(git),flush=True)
        result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        marker='PASS: retained merge engine' if case=='retained' else 'PASS: source block workflow' if case=='blocks' else 'PASS: aligned result rows' if case=='aligned' else 'PASS: ignored conflict'
        if marker not in result.stdout:raise SystemExit('Receiver exited before final assertion.')
