#!/usr/bin/env python3
"""Connected workspace, Finder and shared comparison/drop workflow checkpoint."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
cases=[('workspace','workspace-files-native-2026-10-17.swift','PASS Workspace files:'),('comparison','comparison-launch-native-2026-10-14.swift','Comparison launch:'),('commit-drop','commit-drop-native-2026-10-13.swift','PASS Commit drop:'),('add-drop','add-drop-native-2026-10-13.swift','PASS Add drop/lifetime:'),('finder','finder-transfer-native-2026-10-14.swift','Finder transfers:')]
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--git',type=Path,action='append');parser.add_argument('--captures',type=Path);parser.add_argument('--only',choices=[case[0] for case in cases],action='append')
args=parser.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-workspace-files-') as temporary:
    directory=Path(temporary);env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for name,source,marker in cases:
        if args.only and name not in args.only:continue
        receiver=build_receiver(root,[root/'docs/qa'/source],directory)
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture=directory/(name+str(index));fixture.mkdir();current=env.copy()
            if args.captures and name=='workspace' and index==0:args.captures.mkdir(parents=True,exist_ok=True);current['TURTLEGIT_WORKSPACE_CAPTURE']=str(args.captures.resolve())
            print('Checking '+name+' '+str(git),flush=True)
            result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=current,capture_output=True,text=True)
            print(result.stdout,end='',flush=True);print(result.stderr,end='',flush=True);result.check_returncode()
            if marker not in result.stdout:raise SystemExit('Receiver exited before completion: '+name)
