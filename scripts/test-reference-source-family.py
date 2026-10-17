#!/usr/bin/env python3
"""Grouped source reference-browser and remote-tag native workflows."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
cases={
 'source':('reference-source-native-2026-10-17.swift','ReferenceSourceVerification'),
 'presentation':('reference-presentation-native-2026-10-16.swift','ReferencePresentationVerification'),
 'targets':('reference-menu-targets-native-2026-10-16.swift','ReferenceMenuTargetsVerification'),
 'tags':('remote-tags-native-2026-10-09.swift','RemoteTagVerification'),
 'owned':('remote-management-owned-native-2026-10-16.swift','RemoteManagementOwnedVerification')}
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--git',type=Path,action='append');p.add_argument('--only',choices=cases,action='append');p.add_argument('--captures',type=Path);args=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-reference-source-') as temporary:
    folder=Path(temporary);sources=[]
    for filename,_ in cases.values():
        path=folder/filename;path.write_text((root/'docs/qa'/filename).read_text().replace('@main ', '',1));sources.append(path)
    main=folder/'ReferenceSourceMain.swift';main.write_text('''import AppKit
@main struct ReferenceSourceMain {
 @MainActor static func cleanup() async {RemoteManagementOwnedVerification.windows.forEach {$0.close()};RemoteManagementOwnedVerification.windows=[];await ReferenceSourceVerification.cleanup()}
 @MainActor static func main() async {NSApp.setActivationPolicy(.prohibited);do {switch CommandLine.arguments[3] {
'''+''.join('case "'+case+'": try await '+kind+'.verify()\n' for case,(_,kind) in cases.items())+'''default:fatalError("Unknown reference case")
 };await cleanup();try ReferenceSourceVerification.require(ReferenceBrowserWindowModel.activeReads==0 && ReferenceBrowserWindowModel.activeMutations==0 && RemoteTagWindowModel.activeOperations==0,"Outstanding owned reference operation");print("PASS: reference source family case completed")
 }catch{await cleanup();fputs("FAIL reference source family: \\(error)\\n",stderr);exit(1)}}
}
''')
    receiver=build_receiver(root,sources+[main],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for case in args.only or cases:
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture=folder/(case+str(index));fixture.mkdir();active=env.copy();active.pop('TURTLEGIT_REFERENCE_SOURCE_CAPTURE',None)
            if args.captures and case=='source' and index==0:active['TURTLEGIT_REFERENCE_SOURCE_CAPTURE']=str(args.captures.absolute())
            print('Checking reference '+case+' with '+str(git),flush=True)
            result=run_receiver([str(receiver),str(fixture),str(git.absolute()),case],cwd=root,env=active,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: reference source family case completed' not in result.stdout:raise SystemExit('Receiver exited before final assertions: '+case)
