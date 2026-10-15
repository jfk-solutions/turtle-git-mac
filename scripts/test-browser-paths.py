#!/usr/bin/env python3
"""Grouped byte-exact repository paths and retained browser action/lifecycle checks."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--only',choices=['paths','table','lifecycle'],action='append')
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='TurtleGitBrowserPaths-') as temporary:
    folder=Path(temporary);inputs=root/'build/qa/browser-path-fixtures';inputs.mkdir(parents=True,exist_ok=True)
    sources=[]
    for name in ['repository-browser-paths-native-2026-10-16.swift','repository-browser-table-native-2026-10-13.swift','repository-browser-lifecycle-native-2026-10-13.swift']:
        path=inputs/name;path.write_text((root/'docs/qa'/name).read_text().replace('@main ', '',1));sources.append(path)
    main=inputs/'BrowserPathsMain.swift';main.write_text('import AppKit\n@main struct BrowserPathsMain { @MainActor static func main() async throws { NSApplication.shared.setActivationPolicy(.prohibited); switch ProcessInfo.processInfo.environment["TURTLEGIT_BROWSER_CASE"] { case "table":try await RepositoryBrowserTableVerification.verify();case "lifecycle":try await RepositoryBrowserLifecycleVerification.verify();default:try await RepositoryBrowserPathsVerification.verify() };print("PASS: grouped repository browser case") } }\n')
    receiver=build_receiver(root,sources+[main],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
        for case in args.only or ['paths','table','lifecycle']:
            fixture=folder/(str(index)+'-'+case);fixture.mkdir();env['TURTLEGIT_BROWSER_CASE']=case
            print('Checking browser '+case+' with '+str(git),flush=True)
            legacy_case='repository-browser-table' if case=='table' else 'repository-browser' if case=='lifecycle' else 'repository-browser-paths'
            result=run_receiver([str(receiver),str(fixture),str(git.absolute()),legacy_case],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: grouped repository browser case' not in result.stdout:raise SystemExit('Receiver exited before final assertions.')
