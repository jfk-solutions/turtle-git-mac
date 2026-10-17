#!/usr/bin/env python3
"""Grouped native Merge Open source controls and existing text/patch replacement workflows."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
cases={'source':'MergeOpenSourceVerification','open':'MergeOpenNativeVerification','replacement':'MergeEditorOpenNativeVerification','patch':'MergePatchOpenNativeVerification'}
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--only',choices=cases,action='append');p.add_argument('--captures',type=Path);args=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-open-source-') as temporary:
    folder=Path(temporary);sources=[]
    for name in ['merge-open-source-native-2026-10-17.swift','merge-open-native-2026-10-12.swift','merge-editor-open-native-2026-10-14.swift','merge-patch-open-native-2026-10-14.swift','two-pane-engine-native-2026-10-12.swift','three-pane-engine-native-2026-10-12.swift']:
        path=folder/name;path.write_text((root/'docs/qa'/name).read_text().replace('@main ', '',1));sources.append(path)
    main=folder/'OpenSourceMain.swift';main.write_text('import AppKit\n@main struct OpenSourceMain { @MainActor static func main() async throws { NSApp.setActivationPolicy(.prohibited); switch CommandLine.arguments[1] {\n'+''.join('case "'+case+'": try await '+kind+'.verify()\n' for case,kind in cases.items())+'default: fatalError("Unknown Open case")\n}; print("PASS: Open source family case completed") } }\n')
    receiver=build_receiver(root,sources+[main],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',XDG_CONFIG_HOME=str(folder/'xdg'));env.pop('TURTLEGIT_MERGE_OPEN_CAPTURE',None)
    for case in args.only or cases:
        active=env.copy()
        if args.captures and case=='source':active['TURTLEGIT_MERGE_OPEN_CAPTURE']=str(args.captures.absolute())
        print('Checking Merge Open '+case,flush=True)
        result=run_receiver([str(receiver),case],cwd=root,env=active,capture_output=True,text=True)
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if 'PASS: Open source family case completed' not in result.stdout:raise SystemExit('Receiver exited before final assertions: '+case)
