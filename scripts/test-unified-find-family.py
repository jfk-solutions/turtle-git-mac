#!/usr/bin/env python3
"""Native source Find, standalone document and attached partial staging family."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--captures',type=Path)
parser.add_argument('--only',choices=['source','document','partial'],action='append')
args=parser.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-unified-find-') as temporary:
    folder=Path(temporary);sources=[root/'docs/qa/unified-find-source-native-2026-10-17.swift']
    for name in ['unified-document-native-2026-10-15.swift','partial-patch-native-2026-10-13.swift']:
        path=folder/name;path.write_text((root/'docs/qa'/name).read_text().replace('@main ', '',1));sources.append(path)
    main=folder/'Main.swift'
    main.write_text('''import AppKit
@main struct UnifiedFindMain {
    @MainActor static func main() async {
        _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        do {
            switch ProcessInfo.processInfo.environment["TURTLEGIT_UNIFIED_FIND_CASE"]! {
            case "source":try await UnifiedFindSourceVerification.verify()
            case "document":try await UnifiedDocumentVerification.verify()
            case "partial":try await PartialPatchVerification.verify()
            default:fatalError("Unknown Unified Find case")
            }
            print("PASS: Unified Find family case completed")
        } catch {
            UnifiedFindSourceVerification.owners.forEach{$0.close()}
            for _ in 0..<1500 {
                if PatchWindowModel.activeOperations==0 && PatchDocumentSession.activeOperations==0 {break}
                try? await Task.sleep(nanoseconds:10_000_000)
            }
            fputs("Unified Find family failed: \\(error)\\n",stderr);exit(1)
        }
    }
}
''');sources.append(main)
    receiver=build_receiver(root,sources,folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    env.pop('TURTLEGIT_UNIFIED_DOCUMENT_CAPTURE',None)
    for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
        for case in args.only or ['source','document','partial']:
            fixture=folder/(str(index)+'-'+case);fixture.mkdir();env['TURTLEGIT_UNIFIED_FIND_CASE']=case
            env.pop('TURTLEGIT_UNIFIED_FIND_CAPTURE',None)
            if args.captures and index==0 and case=='source':
                args.captures.mkdir(parents=True,exist_ok=True);env['TURTLEGIT_UNIFIED_FIND_CAPTURE']=str(args.captures.absolute())
            print('Checking Unified Find '+case+' with '+str(git),flush=True)
            result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: Unified Find family case completed' not in result.stdout:raise SystemExit('Unified Find receiver exited before completion.')
