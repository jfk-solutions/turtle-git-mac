#!/usr/bin/env python3
"""Grouped shared message styles/hotspots, retained Input forms, Log and spelling."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver,run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--only',choices=['styles','input','hosts','spelling','font','links','log'],action='append')
parser.add_argument('--captures',type=Path)
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
cases={'log':'try await LogMessageVerification.verify()','links':'try await SourceMessageLinksVerification.verify()','styles':'try await MessageStylesVerification.verify()','input':'try await InputDialogsVerification.run()','hosts':'try await InputHostsVerification.run()','spelling':'MessageSpellingVerification.main()','font':'try await MessageFontVerification.main()'}
with tempfile.TemporaryDirectory(prefix='turtlegit-message-styles-') as temporary:
    folder=Path(temporary); inputs=root/'build/qa/message-style-fixtures';inputs.mkdir(parents=True,exist_ok=True)
    fixtures=[]
    for name in ['log-message-native-2026-10-15.swift','source-message-links-native-2026-10-15.swift','message-styles-native-2026-10-15.swift','input-dialogs-native-2026-10-13.swift','input-hosts-native-2026-10-13.swift','message-spelling-native-2026-10-13.swift','message-font-native-2026-10-08.swift']:
        source=root/'docs/qa'/name; helper=inputs/name
        helper.write_text(source.read_text().replace('@main ', '',1));fixtures.append(helper)
    main=inputs/'MessageStyleMain.swift'
    main.write_text('import AppKit\n@main struct MessageStyleMain { @MainActor static func main() async throws { switch ProcessInfo.processInfo.environment["TURTLEGIT_MESSAGE_STYLE_CASE"]! {\n'+''.join('case "'+key+'": '+value+'\n' for key,value in cases.items())+'default: fatalError("Unknown message case")\n}; print("PASS: Message style case completed") } }\n');fixtures.append(main)
    receiver=build_receiver(root,fixtures,folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
        for case in args.only or cases:
            fixture=folder/(str(index)+'-'+case);fixture.mkdir();env['TURTLEGIT_MESSAGE_STYLE_CASE']=case
            env.pop('TURTLEGIT_MESSAGE_STYLE_CAPTURE',None)
            if args.captures and index==0 and case=='styles':
                args.captures.mkdir(parents=True,exist_ok=True);env['TURTLEGIT_MESSAGE_STYLE_CAPTURE']=str(args.captures.absolute())
            print('Checking message '+case+' with '+str(git),flush=True)
            result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: Message style case completed' not in result.stdout:raise SystemExit('Message receiver exited before completion.')
