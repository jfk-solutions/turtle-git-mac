#!/usr/bin/env python3
"""Grouped exact conflict read/check/selection, Resolve and Rebase file workflows."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
cases={
 'identity':('conflict-identity-native-2026-10-18.swift','ConflictIdentityVerification.verify()'),
 'resolve-mutation':('resolve-mutation-native-2026-10-16.swift','ResolveMutationVerification.main()'),
 'resolve-files':('resolve-file-menu-native-2026-10-16.swift','ResolveFileMenuVerification.main()'),
 'resolve-drop':('resolve-drop-native-2026-10-16.swift','ResolveDropVerification.main()'),
 'resolve-progress':('resolve-progress-native-2026-10-14.swift','ResolveProgressVerification.verify()'),
 'rebase-files':('rebase-conflict-menus-native-2026-10-14.swift','RebaseConflictMenusVerification.verify()'),
 'rebase-refresh':('rebase-session-refresh-native-2026-10-14.swift','RebaseSessionRefreshVerification.verify()')}
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--git',type=Path,action='append');p.add_argument('--only',choices=cases,action='append');args=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-conflict-identities-') as temporary:
 folder=Path(temporary);inputs=root/'build/qa/conflict-identity-fixtures';inputs.mkdir(parents=True,exist_ok=True);sources=[]
 for name,_ in cases.values():
  source=inputs/name;source.write_text((root/'docs/qa'/name).read_text().replace('@main ', '',1));sources.append(source)
 main=inputs/'ConflictIdentityMain.swift';main.write_text('import AppKit\n@main struct ConflictIdentityMain { @MainActor static func main() async throws { NSApp.setActivationPolicy(.prohibited); switch CommandLine.arguments[3] {\n'+''.join('case "'+case+'": try await '+call+'\n' for case,(_,call) in cases.items())+'default: fatalError("Unknown conflict identity case")\n}; print("PASS: conflict identity family case completed") } }\n')
 receiver=build_receiver(root,sources+[main],folder)
 env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
 for case in args.only or cases:
  for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
   directory=folder/(case+str(index));directory.mkdir();print('Checking conflict identity '+case+' with '+str(git),flush=True)
   result=run_receiver([str(receiver),str(directory),str(git.absolute()),case],cwd=root,env=env,capture_output=True,text=True)
   print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
   if 'PASS: conflict identity family case completed' not in result.stdout:raise SystemExit('Conflict receiver exited before final assertions: '+case)
