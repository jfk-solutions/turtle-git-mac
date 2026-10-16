#!/usr/bin/env python3
"""Grouped native patch panel, per-file application and retained import/editor owners."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver,run_receiver
parser=argparse.ArgumentParser(description=__doc__)
cases={'panel':'PatchFilePanelVerification.verify()','files':'FilePatchesVerification.run()','import':'ImportPatchVerification.main()','menus':'MergeCommandMenusVerification.verify()'}
parser.add_argument('--only',choices=cases,action='append')
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--captures',type=Path)
args=parser.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-patch-panel-') as temporary:
    folder=Path(temporary);sources=[]
    for name in ['patch-file-panel-native-2026-10-16.swift','file-patches-native-2026-10-13.swift','import-patch-native-2026-10-08.swift','import-patch-lifecycle-native-2026-10-11.swift','comparison-output-ownership-native-2026-10-15.swift','two-pane-engine-native-2026-10-12.swift','three-pane-engine-native-2026-10-12.swift','merge-command-menus-native-2026-10-16.swift']:
        p=folder/name;p.write_text((root/'docs/qa'/name).read_text().replace('@main ', '',1));sources.append(p)
    main=folder/'PanelMain.swift'
    main.write_text('import AppKit\nimport TurtleGitCore\n@main struct PanelMain { @MainActor static func main() async throws { NSApp.setActivationPolicy(ProcessInfo.processInfo.environment["TURTLEGIT_PATCH_PANEL_CAPTURE"] == nil ? .prohibited : .accessory); switch ProcessInfo.processInfo.environment["TURTLEGIT_PATCH_PANEL_CASE"]! {\n'+''.join('case "'+name+'": try await '+call+'\n' for name,call in cases.items())+'default: fatalError("Unknown patch panel case") };print("PASS: patch panel family case completed") } }\n')
    binary=build_receiver(root,sources+[main],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for case in args.only or cases:
        for index,git in enumerate([Path('/usr/bin/git')] if case=='menus' else args.git or [Path('/usr/bin/git')]):
            fixture=folder/(case+str(index));fixture.mkdir();env['TURTLEGIT_PATCH_PANEL_CASE']=case;env.pop('TURTLEGIT_PATCH_PANEL_CAPTURE',None)
            if args.captures and case=='panel' and index==0:
                args.captures.mkdir(parents=True,exist_ok=True);env['TURTLEGIT_PATCH_PANEL_CAPTURE']=str(args.captures.absolute())
            print('Checking patch panel family '+case+' with '+str(git),flush=True)
            result=run_receiver([str(binary),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: patch panel family case completed' not in result.stdout:raise SystemExit('Patch panel receiver exited without completion.')
