#!/usr/bin/env python3
"""Grouped LFS exact target/owner and retained native interaction workflows."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--only',choices=['identities','interaction'],action='append')
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-lfs-paths-') as temporary:
    folder=Path(temporary);inputs=root/'build/qa/lfs-path-fixtures';inputs.mkdir(parents=True,exist_ok=True)
    sources=[]
    for name in ['lfs-path-identities-native-2026-10-17.swift','lfs-interaction-native-2026-10-15.swift']:
        source=inputs/name;source.write_text((root/'docs/qa'/name).read_text().replace('@main ','',1));sources.append(source)
    main=inputs/'LFSPathsMain.swift'
    main.write_text('import AppKit\n@main struct LFSPathsMain { @MainActor static func main() async throws { NSApplication.shared.setActivationPolicy(.prohibited); switch ProcessInfo.processInfo.environment["TURTLEGIT_LFS_PATH_CASE"]! { case "identities": try await LFSPathIdentityVerification.main(); case "interaction": try await LFSInteractionVerification.main(); default: fatalError("Unknown LFS path case") }; print("PASS: LFS path family case completed") } }\n')
    receiver=build_receiver(root,sources+[main],folder)
    env=dict(os.environ,DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    env.pop('TURTLEGIT_LFS_INTERACTION_CAPTURE',None)
    for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
        for case in args.only or ['identities','interaction']:
            fixture=folder/(str(index)+'-'+case);fixture.mkdir()
            env['TURTLEGIT_LFS_PATH_CASE']=case
            print('Checking LFS '+case+' with '+str(git),flush=True)
            result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: LFS path family case completed' not in result.stdout:raise SystemExit('LFS receiver exited before completion')
