#!/usr/bin/env python3
"""Run the connected Move/Copy/paste/drop family against the built native app."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
cases=[('identities','file-transfer-identities-native-2026-10-17.swift','PASS Transfer identities:'),('move','file-move-native-2026-10-14.swift','File Move:'),('copy','file-transfer-native-2026-10-14.swift','File transfers:'),('drop','file-drop-transfer-native-2026-10-14.swift','PASS drop transfers:'),('rename','rename-workflows-native-2026-10-14.swift','Rename workflows:'),('finder','finder-transfer-native-2026-10-14.swift','Finder transfers:')]
parser.add_argument('--only',choices=[case[0] for case in cases],action='append')
args=parser.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-transfer-family-') as temporary:
    directory=Path(temporary);env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for name,source,marker in cases:
        if args.only and name not in args.only:continue
        receiver=build_receiver(root,[root/'docs/qa'/source],directory)
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture=directory/(name+str(index));fixture.mkdir();print('Checking '+name+' '+str(git),flush=True)
            result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='',flush=True);print(result.stderr,end='',flush=True);result.check_returncode()
            if marker not in result.stdout:raise SystemExit('Receiver exited before completion: '+name)
