#!/usr/bin/env python3
"""Grouped native Submodule Add/Update forms, source layout, selection and progress."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
cases={
 'identity':('submodule-path-identity-native-2026-10-17.swift','try await SubmodulePathIdentityVerification.verify()'),
 'source':('submodule-source-native-2026-10-17.swift','try await SubmoduleSourceVerification.verify()'),
 'inputs':('submodule-add-inputs-native-2026-10-17.swift','try await SubmoduleAddInputsVerification.verify()'),
 'selection':('submodule-update-selection-2026-10-10.swift','try SubmoduleUpdateSelectionReceiver.check()'),
 'progress':('submodule-update-progress-native-2026-10-09.swift','try await SubmoduleUpdateProgressReceiver.run()')}
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--git',type=Path,action='append');p.add_argument('--only',choices=cases,action='append');p.add_argument('--captures',type=Path);args=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-submodule-source-') as temporary:
    folder=Path(temporary);sources=[]
    for name,_ in cases.values():
        path=folder/name;path.write_text((root/'docs/qa'/name).read_text().replace('@main ', '',1));sources.append(path)
    main=folder/'SubmoduleSourceMain.swift';main.write_text('''import AppKit
@main struct SubmoduleSourceMain {
 @MainActor static func cleanup() async throws {
  await SubmodulePathIdentityVerification.cleanup();await SubmoduleSourceVerification.cleanup();try await SubmoduleUpdateProgressReceiver.cleanup()
 }
 @MainActor static func main() async {NSApp.setActivationPolicy(.prohibited);do {switch CommandLine.arguments[3] {
'''+''.join('case "'+case+'": '+call+'\n' for case,(_,call) in cases.items())+'''default:fatalError("Unknown Submodule case")
 };try await cleanup();print("PASS: Submodule source family case completed")
 }catch{let failure=error;do{try await cleanup()}catch{fputs("CLEANUP FAIL \\(error)\\n",stderr)};fputs("FAIL Submodule source family: \\(failure)\\n",stderr);exit(1)}}
}
''')
    receiver=build_receiver(root,sources+[main],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    if args.captures: args.captures.mkdir(parents=True,exist_ok=True)
    for case in args.only or cases:
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture=folder/(case+str(index));fixture.mkdir();active=env.copy()
            for key in ['TURTLEGIT_SUBMODULE_SOURCE_CAPTURE','TURTLEGIT_INPUT_CAPTURE']:active.pop(key,None)
            if args.captures and index==0 and case in ['source','inputs','identity']:
                active['TURTLEGIT_SUBMODULE_SOURCE_CAPTURE' if case in ['source','identity'] else 'TURTLEGIT_INPUT_CAPTURE']=str(args.captures.absolute())
            print('Checking Submodule '+case+' with '+str(git),flush=True)
            result=run_receiver([str(receiver),str(fixture),str(git.absolute()),case],cwd=root,env=active,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: Submodule source family case completed' not in result.stdout:raise SystemExit('Receiver exited before assertions: '+case)
