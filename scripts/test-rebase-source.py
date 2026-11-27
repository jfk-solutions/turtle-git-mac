#!/usr/bin/env python3
"""Grouped source Rebase/Cherry Pick form, references, actions, Add and replay."""
import argparse,json,os,shutil,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
cases={'structural-group':('rebase-structural-no-commit-native-2026-10-26.swift','RebaseStructuralNoCommitVerification'),'source':('rebase-source-native-2026-10-17.swift','RebaseSourceVerification'),'references':('rebase-references-native-2026-10-14.swift','RebaseReferencesVerification'),'controls':('rebase-action-controls-native-2026-10-16.swift','RebaseActionControlsVerification'),'add':('rebase-add-preparation-native-2026-10-16.swift','RebaseAddPreparationVerification'),'replay':('rebase-replay-progress-native-2026-10-14.swift','RebaseReplayProgressVerification')}
ADD_COHORTS=('preparation','reached','no-commit-recovery','no-commit-split')

def receiver_plan(selected_cases,engines):
    # Preserve case/Git order, then each original Add family in source order.
    # All receivers still use the one complete compilation above execution.
    for case in selected_cases:
        for index,git in enumerate(engines):
            for cohort in ADD_COHORTS if case=='add' else (None,):
                yield case,index,git,cohort

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
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0');env.pop('TURTLEGIT_REBASE_SOURCE_CAPTURE',None);env.pop('TURTLEGIT_REBASE_ACTION_CAPTURES',None);env.pop('TURTLEGIT_REBASE_ADD_COHORT',None)
    editor=root/'build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac'
    for case,index,git,cohort in receiver_plan(args.only or cases,args.git or [Path('/usr/bin/git')]):
        label=case+('-'+cohort if cohort else '');context=folder/(label+str(index));context.mkdir();fixture=context/'repository';fixture.mkdir();active=env.copy()
        for name,key in [('home','HOME'),('preferences','CFFIXED_USER_HOME'),('xdg','XDG_CONFIG_HOME'),('temporary','TMPDIR')]:
            private=context/name;private.mkdir(mode=0o700);active[key]=str(private)+('/' if key=='TMPDIR' else '')
        if args.captures and case=='source' and index==0:active['TURTLEGIT_REBASE_SOURCE_CAPTURE']=str(args.captures.absolute())
        if cohort:active['TURTLEGIT_REBASE_ADD_COHORT']=cohort
        print('Checking Rebase '+label+' with '+str(git),flush=True)
        sample=root/('build/qa/rebase-source-'+label+'-'+str(index)+'-'+folder.name+'-timeout.sample.txt')
        result=None
        try:
            result=run_receiver([str(receiver),str(fixture),str(git.absolute()),str(editor),case],cwd=root,env=active,capture_output=True,text=True,timeout_sample=sample)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: Rebase source family case completed' not in result.stdout:raise SystemExit('Receiver exited before final assertions: '+case)
            if cohort and 'PASS: Rebase Add cohort '+cohort not in result.stdout:raise SystemExit('Receiver exited before Add cohort assertions: '+cohort)
        except BaseException as error:
            if case=='add':
                # run_receiver has already reaped its owned receiver before
                # returning/raising. Preserve complete buffered phase timing
                # and private case inputs before TemporaryDirectory removes them.
                evidence=Path(tempfile.mkdtemp(prefix='rebase-source-add-failed-'+cohort+'-'+str(index)+'-',dir=root/'build/qa'))
                shutil.copytree(context,evidence/'context',symlinks=True)
                for name in ('stdout','stderr'):
                    value=getattr(error,name,None)
                    if value is None and result is not None:value=getattr(result,name,None)
                    if value is not None:(evidence/(name+'.log')).write_text(value.decode('utf8',errors='replace') if isinstance(value,bytes) else str(value))
                (evidence/'failure.json').write_text(json.dumps({'case':case,'cohort':cohort,'git':str(git.absolute()),'error':repr(error),'receiver_timeout_seconds':300,'native_wait_iterations':2000,'native_wait_sleep_seconds':0.01,'timeout_sample':str(sample),'timeout_sample_exists':sample.is_file(),'private_context':'context','receiver_cleanup':'run_receiver finally completed before exception reached case driver'},indent=2)+'\n')
                print('Retained private Rebase Add failure evidence: '+str(evidence)+'; timeout sample: '+str(sample),flush=True)
            raise
