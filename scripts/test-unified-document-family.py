#!/usr/bin/env python3
"""Grouped standalone UDiff document and retained partial staging workflows."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--captures',type=Path)
parser.add_argument('--only',choices=['document','partial','handoffs'],action='append')
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-unified-documents-') as temporary:
    folder=Path(temporary);inputs=root/'build/qa/unified-document-fixtures';inputs.mkdir(parents=True,exist_ok=True)
    fixtures=[]
    for name in ['unified-document-native-2026-10-15.swift','partial-patch-native-2026-10-13.swift','unified-handoffs-native-2026-10-15.swift']:
        source=inputs/name;source.write_text((root/'docs/qa'/name).read_text().replace('@main ', '',1));fixtures.append(source)
    main=inputs/'UnifiedDocumentMain.swift'
    main.write_text('import AppKit\n@main struct UnifiedDocumentMain { @MainActor static func main() async throws { switch ProcessInfo.processInfo.environment["TURTLEGIT_UNIFIED_DOCUMENT_CASE"]! {\ncase "document": try await UnifiedDocumentVerification.verify()\ncase "partial": try await PartialPatchVerification.verify()\ncase "handoffs": try await UnifiedHandoffsVerification.verify()\ndefault: fatalError("Unknown UDiff case")\n}; print("PASS: Unified document case completed") } }\n')
    receiver=build_receiver(root,fixtures+[main],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1')
    for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
        for case in args.only or ['document','partial','handoffs']:
            fixture=folder/(str(index)+'-'+case);fixture.mkdir();env['TURTLEGIT_UNIFIED_DOCUMENT_CASE']=case
            env.pop('TURTLEGIT_UNIFIED_DOCUMENT_CAPTURE',None)
            if args.captures and index==0 and case=='document':
                args.captures.mkdir(parents=True,exist_ok=True);env['TURTLEGIT_UNIFIED_DOCUMENT_CAPTURE']=str(args.captures.absolute())
            print('Checking UDiff '+case+' with '+str(git),flush=True)
            result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: Unified document case completed' not in result.stdout:raise SystemExit('Unified document receiver exited before completion.')
