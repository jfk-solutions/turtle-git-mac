#!/usr/bin/env python3
"""Grouped native update downloads, lifetime and App Store isolation."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
cases={'source':'ReleaseUpdateNativeVerification','lifetime':'ReleaseUpdateLifetimeVerification'}
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--only',choices=cases,action='append');p.add_argument('--captures',type=Path);args=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-updates-') as temporary:
    folder=Path(temporary);source=folder/'UpdateNative.swift';source.write_text((root/'docs/qa/release-update-native-2026-10-17.swift').read_text())
    main=folder/'UpdateMain.swift';main.write_text('import AppKit\n@main struct UpdateMain { @MainActor static func main() async throws { NSApplication.shared.setActivationPolicy(.prohibited); switch CommandLine.arguments[1] {\n'+''.join('case "'+case+'": try await '+kind+'.verify()\n' for case,kind in cases.items())+'default: fatalError("Unknown update case")\n}; print("PASS: Release update family case completed") } }\n')
    receiver=build_receiver(root,[source,main],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0');env.pop('TURTLEGIT_UPDATE_CAPTURE',None)
    for case in args.only or cases:
        private=folder/('private-'+case);private.mkdir(mode=0o700)
        for name in ['home','preferences','xdg','temporary']:(private/name).mkdir(mode=0o700)
        active={k:v for k,v in env.items() if not k.startswith('GIT_')}
        active.update(HOME=str(private/'home'),CFFIXED_USER_HOME=str(private/'preferences'),XDG_CONFIG_HOME=str(private/'xdg'),TMPDIR=str(private/'temporary')+'/',GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
        if args.captures and case=='source':active['TURTLEGIT_UPDATE_CAPTURE']=str(args.captures.absolute())
        print('Checking release updates '+case,flush=True)
        result=run_receiver([str(receiver),case],cwd=root,env=active,capture_output=True,text=True)
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if 'PASS: Release update family case completed' not in result.stdout:raise SystemExit('Receiver exited before final assertions: '+case)
