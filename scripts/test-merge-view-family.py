#!/usr/bin/env python3
"""Grouped view switching, native chrome, splitter and retained editor ownership."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver,run_receiver
parser=argparse.ArgumentParser(description=__doc__)
cases={'view':'MergeViewFamilyVerification.verify()','toolbar':'MergeToolbarVerification.main()','open':'MergeEditorOpenNativeVerification.verify()','moved':'MergeMovedBlocksVerification.verify()','wrapped':'MergeWrappedNavigationVerification.verify()','two-pane':'TwoPaneEngineVerification.verify()','three-pane':'ThreePaneEngineVerification.verify(configuration:SubversionMergeConfiguration.bundled())'}
parser.add_argument('--only',choices=cases,action='append')
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--captures',type=Path)
args=parser.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-merge-view-') as temporary:
    folder=Path(temporary);sources=[]
    for name in ['two-pane-engine-native-2026-10-12.swift','three-pane-engine-native-2026-10-12.swift','merge-toolbar-native-2026-10-15.swift','merge-editor-open-native-2026-10-14.swift','merge-moved-blocks-native-2026-10-16.swift','merge-wrapped-navigation-native-2026-10-16.swift','merge-view-family-native-2026-10-16.swift']:
        p=folder/name;p.write_text((root/'docs/qa'/name).read_text().replace('@main ', '',1));sources.append(p)
    main=folder/'ViewMain.swift'
    main.write_text('import AppKit\nimport TurtleGitCore\n@main struct ViewMain { @MainActor static func main() async throws { NSApp.setActivationPolicy(ProcessInfo.processInfo.environment["TURTLEGIT_VIEW_CAPTURE"] == nil ? .prohibited : .accessory);switch ProcessInfo.processInfo.environment["TURTLEGIT_VIEW_CASE"]! {\n'+''.join('case "'+name+'": try await '+call+'\n' for name,call in cases.items())+'default: fatalError("Unknown view case") };print("PASS: view family case completed") } }\n')
    binary=build_receiver(root,sources+[main],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for case in args.only or cases:
        for index,git in enumerate((args.git or [Path('/usr/bin/git')]) if case=='view' else [Path('/usr/bin/git')]):
            fixture=folder/(case+str(index));fixture.mkdir();env['TURTLEGIT_VIEW_CASE']=case;env.pop('TURTLEGIT_VIEW_CAPTURE',None)
            if args.captures and case=='view' and index==0:
                args.captures.mkdir(parents=True,exist_ok=True);env['TURTLEGIT_VIEW_CAPTURE']=str(args.captures.absolute())
            print('Checking view family '+case+' with '+str(git),flush=True)
            result=run_receiver([str(binary),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: view family case completed' not in result.stdout:raise SystemExit('View family receiver exited before completion.')
