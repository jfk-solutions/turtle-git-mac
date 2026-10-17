#!/usr/bin/env python3
"""Grouped native Encoding sheet, Compare transaction and aligned result-format consumers."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
cases={'source':'MergeFormatSourceVerification','compare':'MergeFormatNativeVerification','result':'MergeResultFormatVerification'}
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--only',choices=cases,action='append');p.add_argument('--captures',type=Path);args=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-format-source-') as temporary:
    folder=Path(temporary);sources=[]
    for name in ['merge-format-source-native-2026-10-17.swift','merge-format-native-2026-10-12.swift','merge-result-format-native-2026-10-16.swift','two-pane-engine-native-2026-10-12.swift','three-pane-engine-native-2026-10-12.swift']:
        path=folder/name;path.write_text((root/'docs/qa'/name).read_text().replace('@main ', '',1));sources.append(path)
    main=folder/'FormatSourceMain.swift';main.write_text('import AppKit\n@main struct FormatSourceMain { @MainActor static func main() async throws { NSApp.setActivationPolicy(.prohibited); switch CommandLine.arguments[1] {\n'+''.join('case "'+case+'": try await '+kind+'.verify()\n' for case,kind in cases.items())+'default: fatalError("Unknown format case")\n}; print("PASS: Encoding source family case completed") } }\n')
    receiver=build_receiver(root,sources+[main],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0');env.pop('TURTLEGIT_ENCODING_SOURCE_CAPTURE',None)
    for case in args.only or cases:
        active=env.copy()
        if args.captures and case=='source':active['TURTLEGIT_ENCODING_SOURCE_CAPTURE']=str(args.captures.absolute())
        print('Checking Encoding '+case,flush=True)
        result=run_receiver([str(receiver),case],cwd=root,env=active,capture_output=True,text=True)
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if 'PASS: Encoding source family case completed' not in result.stdout:raise SystemExit('Receiver exited before final assertions: '+case)
