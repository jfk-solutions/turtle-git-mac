#!/usr/bin/env python3
"""Grouped source Branch/Tag forms and connected completion/recovery/pickers."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
cases={'source':'BranchTagSourceVerification','completion':'BranchTagCompletionVerification','handoff':'BranchTagHandoffVerification','pickers':'CreationPickerVerification'}
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--only',choices=cases,action='append');p.add_argument('--git',type=Path,action='append');p.add_argument('--captures',type=Path);args=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-branch-source-') as temporary:
    folder=Path(temporary);sources=[]
    for name in ['branch-tag-source-native-2026-10-17.swift','branch-tag-completion-native-2026-10-16.swift','branch-tag-handoff-native-2026-10-08.swift','creation-pickers-native-2026-10-09.swift']:
        path=folder/name;path.write_text((root/'docs/qa'/name).read_text().replace('@main ', '',1));sources.append(path)
    main=folder/'BranchSourceMain.swift';main.write_text('import AppKit\n@main struct BranchSourceMain { @MainActor static func main() async throws { NSApp.setActivationPolicy(.prohibited); switch CommandLine.arguments[3] {\n'+''.join('case "'+case+'": try await '+kind+('.main()' if case=='handoff' else '.verify()')+'\n' for case,kind in cases.items())+'default: fatalError("Unknown creation case")\n}; print("PASS: Branch/Tag source family case completed") } }\n')
    receiver=build_receiver(root,sources+[main],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0');env.pop('TURTLEGIT_BRANCH_SOURCE_CAPTURE',None)
    for case in args.only or cases:
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture=folder/(case+str(index));fixture.mkdir();active=env.copy()
            if args.captures and case=='source' and index==0:active['TURTLEGIT_BRANCH_SOURCE_CAPTURE']=str(args.captures.absolute())
            print('Checking Branch/Tag '+case+' with '+str(git),flush=True)
            result=run_receiver([str(receiver),str(fixture),str(git.absolute()),case],cwd=root,env=active,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: Branch/Tag source family case completed' not in result.stdout:raise SystemExit('Receiver exited before final assertions: '+case)
