#!/usr/bin/env python3
"""Owned native Compare/Review/Merge source Save As binding checks."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--only',choices=['access','ownership','targets','source','copy'],action='append')
parser.add_argument('--git', type=Path, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='TurtleGitSaveAsTargets-') as temporary:
    directory = Path(temporary)
    sources=[]
    for name in ['merge-result-copy-native-2026-10-17.swift','save-as-targets-native-2026-10-15.swift','merge-save-ownership-native-2026-10-16.swift','merge-save-access-native-2026-10-16.swift','merge-source-tools-native-2026-10-14.swift','two-pane-engine-native-2026-10-12.swift','three-pane-engine-native-2026-10-12.swift']:
        source=directory/name;source.write_text((root/'docs/qa'/name).read_text().replace('@main ', '',1));sources.append(source)
    main=directory/'SaveMain.swift'
    main.write_text('import AppKit\n@main struct SaveMain { @MainActor static func main() async throws { NSApp.setActivationPolicy(.prohibited); if ProcessInfo.processInfo.environment["TURTLEGIT_SAVE_CASE"] == "copy" {try await MergeResultCopyVerification.verify()} else if ProcessInfo.processInfo.environment["TURTLEGIT_SAVE_CASE"] == "source" {try await MergeSourceToolsNativeVerification.verify()} else if ProcessInfo.processInfo.environment["TURTLEGIT_SAVE_CASE"] == "access" {try await MergeSaveAccessVerification.verify()} else if ProcessInfo.processInfo.environment["TURTLEGIT_SAVE_CASE"] == "ownership" {try await MergeSaveOwnershipVerification.verify()} else {try await SaveAsTargetsVerification.main()};print("PASS: save family case completed") } }\n')
    executable = build_receiver(root, sources+[main], directory)
    environment = os.environ.copy()
    environment.update(DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
    for case in args.only or ['access','ownership','targets','source','copy']:
        environment['TURTLEGIT_SAVE_CASE']=case
        for index, git in enumerate([Path('/usr/bin/git')] if case=='source' else args.git or [Path('/usr/bin/git')]):
            fixture = directory / (case+str(index)); fixture.mkdir()
            print('Checking save family '+case+' with ' + str(git), flush=True)
            result=run_receiver([str(executable), str(fixture), str(git.absolute())], cwd=root, env=environment, capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: save family case completed' not in result.stdout:raise SystemExit('Save receiver exited without completion')
