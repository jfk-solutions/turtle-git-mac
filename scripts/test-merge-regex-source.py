#!/usr/bin/env python3
"""Grouped source regex list/editor and retained actual comparison filtering."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
cases={'source':'MergeRegexSourceVerification','comparison':'MergeRegexNativeVerification','files':'MergeRegexFilesVerification'}
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--only',choices=cases,action='append');p.add_argument('--captures',type=Path);args=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-regex-source-') as temporary:
    folder=Path(temporary);sources=[]
    for name in ['merge-regex-source-native-2026-10-17.swift','merge-regex-native-2026-10-12.swift','merge-regex-files-native-2026-10-17.swift']:
        path=folder/name;path.write_text((root/'docs/qa'/name).read_text().replace('@main ', '',1));sources.append(path)
    main=folder/'RegexSourceMain.swift';main.write_text('import AppKit\n@main struct RegexSourceMain { @MainActor static func main() async throws { NSApp.setActivationPolicy(.prohibited); let parser = URL(fileURLWithPath: CommandLine.arguments[2]); switch CommandLine.arguments[1] {\n'+''.join('case "'+case+'": try await '+kind+'.verify(parser: parser)\n' for case,kind in cases.items())+'default: fatalError("Unknown regex case")\n}; print("PASS: Regex source family case completed") } }\n')
    receiver=build_receiver(root,sources+[main],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0');env.pop('TURTLEGIT_REGEX_SOURCE_CAPTURE',None)
    parser=root/'build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/IssueRegex/issue-regex'
    for case in args.only or cases:
        active=env.copy()
        if args.captures and case=='source':active['TURTLEGIT_REGEX_SOURCE_CAPTURE']=str(args.captures.absolute())
        if args.captures and case=='files':active['TURTLEGIT_REGEX_FILES_CAPTURE']=str(args.captures.absolute())
        print('Checking regex '+case,flush=True)
        result=run_receiver([str(receiver),case,str(parser)],cwd=root,env=active,capture_output=True,text=True)
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if 'PASS: Regex source family case completed' not in result.stdout:raise SystemExit('Receiver exited before final assertions: '+case)
