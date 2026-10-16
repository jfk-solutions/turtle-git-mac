#!/usr/bin/env python3
"""Native Email settings and source credential editor; private preferences/credential actor only."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
cases=[('editor','email-credential-editor-native-2026-10-17.swift','PASS Email credential editor:'),('settings','email-settings-native-2026-10-10.swift','Email settings:')]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--only',choices=[x[0] for x in cases],action='append');p.add_argument('--captures',type=Path);args=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-email-credentials-') as temporary:
    folder=Path(temporary);env=os.environ.copy();env['DYLD_FRAMEWORK_PATH']=str(root/'build/Build/Products/Debug')
    for name,source,marker in cases:
        if args.only and name not in args.only:continue
        receiver=build_receiver(root,[root/'docs/qa'/source],folder)
        env.pop('TURTLEGIT_EMAIL_CAPTURE',None)
        if args.captures and name=='editor':env['TURTLEGIT_EMAIL_CAPTURE']=str(args.captures.absolute())
        result=run_receiver([str(receiver)],cwd=root,env=env,capture_output=True,text=True)
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if marker not in result.stdout:raise SystemExit('Receiver did not finish: '+name)
