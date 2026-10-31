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
    env={key:value for key,value in os.environ.items() if not key.startswith('GIT_')};env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0');env.pop('TURTLEGIT_BRANCH_SOURCE_CAPTURE',None)
    for case in args.only or cases:
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            case_root=folder/(case+str(index));case_root.mkdir(mode=0o700)
            private={name:case_root/name for name in ('repository','home','preferences','xdg','temporary')}
            for directory in private.values():directory.mkdir(mode=0o700)
            fixture=private['repository'];active=env.copy()
            active.update(HOME=str(private['home']),CFFIXED_USER_HOME=str(private['preferences']),
                          XDG_CONFIG_HOME=str(private['xdg']),TMPDIR=str(private['temporary'])+'/')
            if args.captures and case=='source' and index==0:active['TURTLEGIT_BRANCH_SOURCE_CAPTURE']=str(args.captures.absolute())
            print('Checking Branch/Tag '+case+' with '+str(git),flush=True)
            result=run_receiver([str(receiver),str(fixture),str(git.absolute()),case],cwd=root,env=active,capture_output=True,text=True,timeout_sample=case_root/'timeout.sample.txt')
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: Branch/Tag source family case completed' not in result.stdout:raise SystemExit('Receiver exited before final assertions: '+case)
