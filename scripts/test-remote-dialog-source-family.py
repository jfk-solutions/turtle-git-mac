#!/usr/bin/env python3
"""Connected Add Remote, Select Remote Ref and parent transport/settings workflows."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
cases={
 'source':('remote-dialog-source-native-2026-10-17.swift','RemoteDialogSourceVerification.verify()'),
 'dialogs':('remote-dialogs-native-2026-10-13.swift','RemoteDialogsVerification.run()'),
 'management':('remote-management-family-native-2026-10-14.swift','RemoteManagementFamilyVerification.verify()')}
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--git',type=Path,action='append');p.add_argument('--only',choices=cases,action='append');p.add_argument('--captures',type=Path);args=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-remote-dialog-source-') as temporary:
    folder=Path(temporary);sources=[]
    for filename,_ in cases.values():
        path=folder/filename;path.write_text((root/'docs/qa'/filename).read_text().replace('@main ', '',1));sources.append(path)
    main=folder/'RemoteDialogMain.swift';main.write_text("import AppKit\n@main struct RemoteDialogMain { @MainActor static func main() async throws { _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited);switch CommandLine.arguments[3] {\n"+''.join('case "'+case+'": try await '+call+'\n' for case,(_,call) in cases.items())+'default:fatalError("Unknown remote dialog case") }; print("PASS: remote dialog source family completed") } }\n')
    receiver=build_receiver(root,sources+[main],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for case in args.only or cases:
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture=folder/(case+str(index));fixture.mkdir();active=env.copy();active.pop('TURTLEGIT_REMOTE_DIALOG_CAPTURE',None)
            if args.captures and case=='source' and index==0:
                args.captures.mkdir(parents=True,exist_ok=True);active['TURTLEGIT_REMOTE_DIALOG_CAPTURE']=str(args.captures.absolute())
            print('Checking remote dialog '+case+' with '+str(git),flush=True)
            result=run_receiver([str(receiver),str(fixture),str(git.absolute()),case],cwd=root,env=active,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: remote dialog source family completed' not in result.stdout:raise SystemExit('Remote dialog receiver exited before final assertions: '+case)
