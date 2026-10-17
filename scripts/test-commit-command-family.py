#!/usr/bin/env python3
"""Grouped Commit native command, selection, history and remembered-action checks."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
parser=argparse.ArgumentParser(description=__doc__)
cases={'commands':'CommitCommandMenuVerification.verify()','staging':'CommitStagingListVerification.verify()','history':'CommitHistoryVerification.verify()','actions':'CommitLastActionVerification.main()','focus':'CommitBranchFocusVerification.main()','identities':'WorkingSelectionIdentitiesVerification.verify()'}
parser.add_argument('--only',choices=cases,action='append');parser.add_argument('--git',type=Path,action='append');parser.add_argument('--captures',type=Path);args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-commit-commands-') as temporary:
    directory=Path(temporary);sources=[]
    selected=args.only or list(cases)
    names=dict(zip(cases,['commit-command-menu-native-2026-10-16.swift','commit-staging-list-native-2026-10-16.swift','commit-history-native-2026-10-10.swift','commit-last-action-native-2026-10-08.swift','commit-branch-focus-native-2026-10-09.swift','working-selection-identities-native-2026-10-17.swift']))
    for name in [names[case] for case in selected]:
        source=directory/name;source.write_text((root/'docs/qa'/name).read_text().replace('@main ', '',1));sources.append(source)
    main=directory/'CommitMain.swift';main.write_text('import AppKit\n@main struct CommitMain { @MainActor static func main() async throws {NSApp.setActivationPolicy(.prohibited);switch ProcessInfo.processInfo.environment["TURTLEGIT_COMMIT_CASE"]! {\n'+''.join('case "'+case+'":try await '+call+'\n' for case,call in cases.items() if case in selected)+'default:fatalError("Unknown Commit case")};print("PASS: Commit command family case completed")} }\n')
    receiver=build_receiver(root,sources+[main],directory)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for case in selected:
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture=directory/(case+str(index));fixture.mkdir();env['TURTLEGIT_COMMIT_CASE']=case
            env.pop('TURTLEGIT_EXACT_SELECTION_CAPTURE',None)
            if args.captures and case=='identities' and index==0:
                args.captures.mkdir(parents=True,exist_ok=True);env['TURTLEGIT_EXACT_SELECTION_CAPTURE']=str(args.captures.resolve())
            print('Checking Commit '+case+' with '+str(git),flush=True)
            result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: Commit command family case completed' not in result.stdout:raise SystemExit('Commit receiver exited without completion')
