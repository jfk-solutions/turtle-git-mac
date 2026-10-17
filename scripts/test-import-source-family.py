#!/usr/bin/env python3
"""Grouped source Import Patch native form and retained serial-import/recovery workflows."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--git',type=Path,action='append');p.add_argument('--only',choices=['source','workflow'],action='append');p.add_argument('--captures',type=Path);args=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-import-source-') as temporary:
    folder=Path(temporary);sources=[]
    for name in ['import-source-native-2026-10-17.swift','import-patch-native-2026-10-08.swift','import-patch-lifecycle-native-2026-10-11.swift','comparison-output-ownership-native-2026-10-15.swift']:
        path=folder/name;path.write_text((root/'docs/qa'/name).read_text().replace('@main ', '',1));sources.append(path)
    main=folder/'ImportSourceMain.swift';main.write_text('''import AppKit
@main struct ImportSourceMain {
 @MainActor static func main() async {NSApp.setActivationPolicy(.prohibited);do {switch CommandLine.arguments[3] {
 case "source":try await ImportSourceVerification.verify()
 case "workflow":try await ImportPatchVerification.main()
 default:fatalError("Unknown import case")
 };await ImportSourceVerification.cleanup();try ImportSourceVerification.require(ImportPatchWindowModel.activeWorkers==0,"Outstanding owned Import work");print("PASS: Import source family case completed")
 }catch{await ImportSourceVerification.cleanup();fputs("FAIL Import source family: \\(error)\\n",stderr);exit(1)}}
}
''')
    receiver=build_receiver(root,sources+[main],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for key in ['TURTLEGIT_IMPORT_LIFECYCLE_ONLY','TURTLEGIT_OUTPUT_OWNERSHIP_ONLY','TURTLEGIT_IMPORT_SOURCE_CAPTURE']:env.pop(key,None)
    for case in args.only or ['source','workflow']:
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture=folder/(case+str(index));fixture.mkdir();active=env.copy()
            if args.captures and case=='source' and index==0:active['TURTLEGIT_IMPORT_SOURCE_CAPTURE']=str(args.captures.absolute())
            print('Checking Import '+case+' with '+str(git),flush=True)
            result=run_receiver([str(receiver),str(fixture),str(git.absolute()),case],cwd=root,env=active,capture_output=True,text=True,timeout=300)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: Import source family case completed' not in result.stdout:raise SystemExit('Receiver exited before assertions: '+case)
