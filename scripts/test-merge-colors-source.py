#!/usr/bin/env python3
"""Grouped Merge Colors captured source context, retained palette and shared Settings controls."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
cases={'source':'MergeColorsSourceVerification','merge':'MergeColorsNativeVerification','shared':'SettingsColorChoicesVerification'}
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--only',choices=cases,action='append');p.add_argument('--captures',type=Path);args=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-merge-colors-source-') as temporary:
    folder=Path(temporary);sources=[]
    for name in ['merge-colors-source-native-2026-10-17.swift','merge-colors-native-2026-10-12.swift','settings-color-choices-native-2026-10-16.swift']:
        path=folder/name;path.write_text((root/'docs/qa'/name).read_text().replace('@main ', '',1));sources.append(path)
    main=folder/'ColorsSourceMain.swift';main.write_text('import AppKit\n@main struct ColorsSourceMain { @MainActor static func main() async throws { NSApp.setActivationPolicy(.prohibited); switch CommandLine.arguments[1] {\n'+''.join('case "'+case+'": try await '+kind+'.verify()\n' for case,kind in cases.items())+'default: fatalError("Unknown color case")\n}; print("PASS: Merge Colors source family case completed") } }\n')
    receiver=build_receiver(root,sources+[main],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0');env.pop('TURTLEGIT_SETTINGS_COLOR_CAPTURES',None);env.pop('TURTLEGIT_MERGE_COLORS_CAPTURE',None)
    for case in args.only or cases:
        active=env.copy()
        if args.captures and case=='source':active['TURTLEGIT_MERGE_COLORS_CAPTURE']=str(args.captures.absolute())
        print('Checking Merge Colors '+case,flush=True)
        result=run_receiver([str(receiver),case],cwd=root,env=active,capture_output=True,text=True)
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if 'PASS: Merge Colors source family case completed' not in result.stdout:raise SystemExit('Receiver exited before final assertions: '+case)
