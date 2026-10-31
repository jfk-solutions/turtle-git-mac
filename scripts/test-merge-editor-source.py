#!/usr/bin/env python3
"""Grouped source Merge Editor form/profile ownership and actual preference consumers."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
cases={'source':'MergeEditorSourceVerification','general':'MergeGeneralVerification','encoding':'MergeDefaultEncodingVerification','patch':'MergePatchNativeVerification'}
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--only',choices=cases,action='append');p.add_argument('--captures',type=Path);args=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-merge-editor-source-') as temporary:
    folder=Path(temporary);sources=[]
    for name in ['merge-editor-source-native-2026-10-17.swift','merge-general-native-2026-10-12.swift','merge-default-encoding-native-2026-10-12.swift','merge-patch-native-2026-10-12.swift','two-pane-engine-native-2026-10-12.swift']:
        path=folder/name;path.write_text((root/'docs/qa'/name).read_text().replace('@main ', '',1));sources.append(path)
    main=folder/'EditorSourceMain.swift';main.write_text('import AppKit\n@main struct EditorSourceMain { @MainActor static func main() async throws { NSApplication.shared.setActivationPolicy(.prohibited); switch CommandLine.arguments[1] {\n'+''.join('case "'+case+'": try await '+kind+'.verify()\n' for case,kind in cases.items())+'default: fatalError("Unknown editor settings case")\n}; print("PASS: Merge Editor source family case completed") } }\n')
    receiver=build_receiver(root,sources+[main],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0');env.pop('TURTLEGIT_MERGE_EDITOR_CAPTURE',None)
    for case in args.only or cases:
        private=folder/('case-'+case);private.mkdir(mode=0o700)
        for name in ['home','preferences','xdg','temporary']:(private/name).mkdir(mode=0o700)
        active={key:value for key,value in env.items() if not key.startswith('GIT_')}
        active.update(HOME=str(private/'home'),CFFIXED_USER_HOME=str(private/'preferences'),XDG_CONFIG_HOME=str(private/'xdg'),TMPDIR=str(private/'temporary')+'/',GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
        if args.captures and case=='source':active['TURTLEGIT_MERGE_EDITOR_CAPTURE']=str(args.captures.absolute())
        print('Checking Merge Editor '+case,flush=True)
        result=run_receiver([str(receiver),case],cwd=root,env=active,capture_output=True,text=True)
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if 'PASS: Merge Editor source family case completed' not in result.stdout:raise SystemExit('Receiver exited before final assertions: '+case)
