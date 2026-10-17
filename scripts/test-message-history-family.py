#!/usr/bin/env python3
"""Connected native history dialog, Commit insertion and Merge handoffs."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--git',type=Path,action='append');p.add_argument('--only',choices=['source','picker','commit','merge'],action='append');p.add_argument('--captures',type=Path);a=p.parse_args();root=Path(__file__).resolve().parent.parent
cases=[('source','message-history-source-native-2026-10-17.swift'),('picker','history-picker-native-2026-10-08.swift'),('commit','commit-history-native-2026-10-10.swift'),('merge','merge-history-native-2026-10-08.swift')]
with tempfile.TemporaryDirectory(prefix='tg-message-history-family-') as temporary:
    directory=Path(temporary);env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for case,source in cases:
        if a.only and case not in a.only:continue
        receiver=build_receiver(root,[root/'docs/qa'/source],directory)
        engines=a.git or [Path('/usr/bin/git')]
        if case=='picker':engines=engines[:1]
        for index,git in enumerate(engines):
            fixture=directory/(case+str(index));fixture.mkdir();current=env.copy()
            if a.captures and case=='source' and index==0:a.captures.mkdir(parents=True,exist_ok=True);current['TURTLEGIT_HISTORY_CAPTURE']=str(a.captures.absolute())
            print('Checking message history '+case+' '+str(git),flush=True)
            result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=current,capture_output=True,text=True)
            print(result.stdout,end='',flush=True);print(result.stderr,end='',flush=True);result.check_returncode()
            if 'PASS' not in result.stdout:raise SystemExit('History receiver exited before completion')
