#!/usr/bin/env python3
"""Native tool settings source forms, Browse owners, Advanced table and retained settings transactions."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
cases=[('source','tool-source-family-native-2026-10-17.swift','PASS Tool source family:'),('settings','tool-settings-native-2026-10-12.swift','Tools: association Add/Edit/Cancel'),('navigation','settings-family-native-2026-10-13.swift','Settings family: actual navigation/cached Apply/Cancel')]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--only',choices=[x[0] for x in cases],action='append');p.add_argument('--captures',type=Path);args=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-tool-source-') as temporary:
    folder=Path(temporary);env=os.environ.copy();env['DYLD_FRAMEWORK_PATH']=str(root/'build/Build/Products/Debug')
    for name,source,marker in cases:
        if args.only and name not in args.only:continue
        receiver=build_receiver(root,[root/'docs/qa'/source],folder)
        env.pop('TURTLEGIT_TOOL_CAPTURE',None)
        if args.captures and name=='source':env['TURTLEGIT_TOOL_CAPTURE']=str(args.captures.absolute())
        result=run_receiver([str(receiver),str(folder/(name+"-fixture")),"/usr/bin/git"],cwd=root,env=env,capture_output=True,text=True)
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if marker not in result.stdout:raise SystemExit('Receiver did not finish: '+name)
