#!/usr/bin/env python3
"""Group image toolbar, Open, selection and frame lifetime checks in one build."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--captures',type=Path)
parser.add_argument('--only',choices=['overlay','drop','pointer','toolbar','open','conflict','frames','routing','conflict-routing','conflict-owned'],action='append')
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
cases={'overlay':'ImageOverlayInspectionVerification','drop':'ImageDropVerification','pointer':'ImagePointerVerification','toolbar':'ImageToolbarVerification','open':'ImageOpenVerification','conflict':'ImageConflictVerification','frames':'ImageFramesVerification','routing':'ImageToolRoutingVerification','conflict-routing':'ConflictEditorRoutingVerification','conflict-owned':'ImageConflictOwnedVerification'}
with tempfile.TemporaryDirectory(prefix='turtlegit-image-commands-') as temporary:
    folder=Path(temporary); fixtures=[]
    inputs=root/'build/qa/image-command-fixtures';inputs.mkdir(parents=True,exist_ok=True)
    for name in ['image-overlay-inspection-native-2026-10-24.swift','image-drop-native-2026-10-16.swift','image-pointer-native-2026-10-16.swift','image-open-native-2026-10-10.swift','image-conflict-native-2026-10-10.swift','image-frames-native-2026-10-10.swift','image-toolbar-native-2026-10-15.swift','image-tool-routing-native-2026-10-16.swift','conflict-editor-routing-native-2026-10-14.swift','image-conflict-owned-native-2026-10-16.swift']:
        source=root/'docs/qa'/name; helper=inputs/name
        helper.write_text(source.read_text().replace('@main ', '',1)); fixtures.append(helper)
    main=inputs/'ImageCommandMain.swift'
    main.write_text('import AppKit\n@main struct ImageCommandMain { @MainActor static func main() async throws { NSApplication.shared.setActivationPolicy(.prohibited); switch ProcessInfo.processInfo.environment["TURTLEGIT_IMAGE_COMMAND_CASE"]! {\n' + ''.join('case "'+case+'": try await '+kind+'.verify()\n' for case,kind in cases.items()) + 'default: fatalError("Unknown image case")\n}; print("PASS: Image command case completed") } }\n')
    fixtures.append(main); receiver=build_receiver(root,fixtures,folder)
    env=os.environ.copy(); env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1')
    for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
        for case in args.only or cases:
            fixture=folder/(str(index)+'-'+case);fixture.mkdir()
            env['TURTLEGIT_IMAGE_COMMAND_CASE']=case
            env.pop('TURTLEGIT_IMAGE_TOOLBAR_CAPTURE',None)
            env.pop('TURTLEGIT_IMAGE_CONFLICT_CAPTURE',None)
            if args.captures and index==0 and case=='conflict-owned':
                args.captures.mkdir(parents=True,exist_ok=True);env['TURTLEGIT_IMAGE_CONFLICT_CAPTURE']=str(args.captures.absolute())
            if args.captures and index==0 and case in ['toolbar','overlay']:
                args.captures.mkdir(parents=True,exist_ok=True);env['TURTLEGIT_IMAGE_TOOLBAR_CAPTURE']=str(args.captures.absolute())
            print('Checking image '+case+' with '+str(git),flush=True)
            result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: Image command case completed' not in result.stdout:
                raise SystemExit('Image receiver exited before its completion marker.')
