#!/usr/bin/env python3
"""Grouped native patch panel, per-file application and retained import/editor owners."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver,run_receiver

cases={'special':'PatchSpecialRecoveryVerification.verify()','recovery':'PatchRecoveryVerification.verify()','panel':'PatchFilePanelVerification.verify()','files':'FilePatchesVerification.run()','import':'ImportPatchVerification.main()','menus':'MergeCommandMenusVerification.verify()'}
FAMILIES={
    'patch':('special','recovery','panel','files'),
    'import':('import',),
    'menus':('menus',),
}
# Keep complete fixture bodies and their actual cross-fixture dependencies.
# Hosted step319 exhausted the unchanged 300s compiler deadline when all ten
# fixtures shared one per-file invocation. Each cohesive family now has its own
# normal native_receiver cache entry, with the same app/framework/toolchain keys.
FIXTURES={
    'patch':('patch-special-recovery-native-2026-10-16.swift','patch-recovery-native-2026-10-16.swift','patch-file-panel-native-2026-10-16.swift','file-patches-native-2026-10-13.swift','merge-command-menus-native-2026-10-16.swift','two-pane-engine-native-2026-10-12.swift','three-pane-engine-native-2026-10-12.swift'),
    'import':('import-patch-native-2026-10-08.swift','import-patch-lifecycle-native-2026-10-11.swift','comparison-output-ownership-native-2026-10-15.swift'),
    'menus':('merge-command-menus-native-2026-10-16.swift','two-pane-engine-native-2026-10-12.swift','three-pane-engine-native-2026-10-12.swift'),
}


def family_for(case):
    return next(family for family,selected in FAMILIES.items() if case in selected)


def build_family(root,family,folder,*,build=build_receiver):
    folder.mkdir(parents=True,exist_ok=True)
    sources=[]
    for name in FIXTURES[family]:
        source=folder/name
        source.write_text((root/'docs/qa'/name).read_text().replace('@main ', '',1))
        sources.append(source)
    main=folder/'PanelMain.swift'
    main.write_text('import AppKit\nimport TurtleGitCore\n@main struct PanelMain { @MainActor static func main() async throws { NSApp.setActivationPolicy(ProcessInfo.processInfo.environment["TURTLEGIT_PATCH_PANEL_CAPTURE"] == nil ? .prohibited : .accessory); switch ProcessInfo.processInfo.environment["TURTLEGIT_PATCH_PANEL_CASE"]! {\n'+''.join('case "'+name+'": try await '+cases[name]+'\n' for name in FAMILIES[family])+'default: fatalError("Unknown patch panel case") };print("PASS: patch panel family case completed") } }\n')
    print('Compiling patch panel family '+family+' ('+str(len(sources))+' fixtures)',flush=True)
    return build(root,sources+[main],folder,fixture_mode='per-file')


def run_workflows(root,folder,selected,engines,*,captures=None,build=build_receiver,run=run_receiver,environ=None):
    receivers={}
    for family in dict.fromkeys(family_for(case) for case in selected):
        receivers[family]=build_family(root,family,folder/('family-'+family),build=build)
    env=dict(os.environ if environ is None else environ)
    env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    # Compilation grouping must not regroup runtime cases or expand menus to a
    # second Git engine: retain the original case-outer/engine-inner contract.
    for case in selected:
        for index,git in enumerate([Path('/usr/bin/git')] if case=='menus' else engines):
            fixture=folder/(case+str(index));fixture.mkdir()
            env['TURTLEGIT_PATCH_PANEL_CASE']=case;env.pop('TURTLEGIT_PATCH_PANEL_CAPTURE',None)
            if captures and case in ['special','recovery','panel'] and index==0:
                captures.mkdir(parents=True,exist_ok=True);env['TURTLEGIT_PATCH_PANEL_CAPTURE']=str(captures.absolute())
            print('Checking patch panel family '+case+' with '+str(git),flush=True)
            result=run([str(receivers[family_for(case)]),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: patch panel family case completed' not in result.stdout:raise SystemExit('Patch panel receiver exited without completion.')


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--only',choices=cases,action='append')
    parser.add_argument('--git',type=Path,action='append')
    parser.add_argument('--captures',type=Path)
    args=parser.parse_args(argv);root=Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix='turtlegit-patch-panel-') as temporary:
        run_workflows(root,Path(temporary),args.only or list(cases),args.git or [Path('/usr/bin/git')],captures=args.captures)


if __name__=='__main__':main()
