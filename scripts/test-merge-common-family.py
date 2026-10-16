#!/usr/bin/env python3
"""Grouped common-record, whitespace, terminal and moved-block native workflows."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
cases={'common':'MergeCommonRecordsVerification','whitespace':'MergeWhitespaceStatesVerification','terminal':'MergeTerminalRecordVerification','moved':'MergeMovedBlocksVerification'}
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--only',choices=cases,action='append');args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-common-records-') as temporary:
    folder=Path(temporary);sources=[]
    for name in ['merge-common-records-native-2026-10-16.swift','merge-whitespace-states-native-2026-10-15.swift','merge-terminal-record-native-2026-10-16.swift','merge-moved-blocks-native-2026-10-16.swift','merge-margin-native-2026-10-16.swift','two-pane-engine-native-2026-10-12.swift','three-pane-engine-native-2026-10-12.swift']:
        path=folder/name;path.write_text((root/'docs/qa'/name).read_text().replace('@main ', '',1));sources.append(path)
    main=folder/'CommonMain.swift'
    main.write_text('import AppKit\n@main struct CommonMain { @MainActor static func main() async throws { NSApp.setActivationPolicy(.prohibited); switch CommandLine.arguments[2] {\n'+''.join('case "'+case+'": try await '+kind+'.verify()\n' for case,kind in cases.items())+'default: fatalError("Unknown common-record case")\n}; print("PASS: common-record family case completed") } }\n')
    receiver=build_receiver(root,sources+[main],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0');env.pop('TURTLEGIT_WRAP_CAPTURE',None)
    for case in args.only or cases:
        directory=folder/case;directory.mkdir();print('Checking common-record family '+case,flush=True)
        result=run_receiver([str(receiver),str(directory),case],cwd=root,env=env,capture_output=True,text=True)
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if 'PASS: common-record family case completed' not in result.stdout:raise SystemExit('Receiver exited before final assertions: '+case)
