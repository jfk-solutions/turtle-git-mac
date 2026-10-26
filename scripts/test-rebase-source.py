#!/usr/bin/env python3
"""Grouped source Rebase/Cherry Pick form, references, actions, Add and replay."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
cases={'structural-group':('rebase-structural-no-commit-native-2026-10-26.swift','RebaseStructuralNoCommitVerification'),'source':('rebase-source-native-2026-10-17.swift','RebaseSourceVerification'),'references':('rebase-references-native-2026-10-14.swift','RebaseReferencesVerification'),'controls':('rebase-action-controls-native-2026-10-16.swift','RebaseActionControlsVerification'),'add':('rebase-add-preparation-native-2026-10-16.swift','RebaseAddPreparationVerification'),'replay':('rebase-replay-progress-native-2026-10-14.swift','RebaseReplayProgressVerification')}
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--git',type=Path,action='append');p.add_argument('--only',choices=cases,action='append');p.add_argument('--captures',type=Path);args=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-rebase-source-') as temporary:
    folder=Path(temporary);sources=[]
    for name,_ in cases.values():
        path=folder/name;path.write_text((root/'docs/qa'/name).read_text().replace('@main ', '',1));sources.append(path)
    main=folder/'RebaseSourceMain.swift';main.write_text('''import AppKit
@main struct RebaseSourceMain {
 @MainActor static func cleanup() async {
  for window in NSApp.windows {if let owner=window.delegate as? RebaseWindowController {owner.close()}}
  for _ in 0..<3000 {if RebaseWindowModel.activeReplayOperations==0 && RebaseWindowModel.activePreparationReads==0 && RebaseWindowModel.activeColumnReads==0 {return};try? await Task.sleep(nanoseconds:10_000_000)}
 }
 @MainActor static func main() async {NSApp.setActivationPolicy(.prohibited);do {switch CommandLine.arguments[4] {
'''+''.join('case "'+case+'": try await '+kind+'.verify()\n' for case,(_,kind) in cases.items())+'''default:fatalError("Unknown Rebase case")
 };await cleanup();print("PASS: Rebase source family case completed")
 }catch{await cleanup();fputs("FAIL Rebase source family: \\(error)\\n",stderr);exit(1)}}
}
''')
    receiver=build_receiver(root,sources+[main],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0');env.pop('TURTLEGIT_REBASE_SOURCE_CAPTURE',None);env.pop('TURTLEGIT_REBASE_ACTION_CAPTURES',None)
    editor=root/'build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac'
    for case in args.only or cases:
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture=folder/(case+str(index));fixture.mkdir();active=env.copy()
            if args.captures and case=='source' and index==0:active['TURTLEGIT_REBASE_SOURCE_CAPTURE']=str(args.captures.absolute())
            print('Checking Rebase '+case+' with '+str(git),flush=True)
            result=run_receiver([str(receiver),str(fixture),str(git.absolute()),str(editor),case],cwd=root,env=active,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: Rebase source family case completed' not in result.stdout:raise SystemExit('Receiver exited before final assertions: '+case)
