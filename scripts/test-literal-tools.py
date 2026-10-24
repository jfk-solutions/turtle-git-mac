#!/usr/bin/env python3
"""Cached private native tool settings identities, associations and chooser ownership."""
import argparse
import json
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--only',choices=['forms','associations','chooser'],action='append')
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
cache=root/'build/qa/literal-tools-native-sources';cache.mkdir(parents=True,exist_ok=True)
receiver=build_receiver(root,[root/'docs/qa/literal-tools-native-2026-10-24.swift'],cache)
results=[]
for case in args.only or ['forms','associations','chooser']:
    with tempfile.TemporaryDirectory(prefix='turtlegit-literal-tools-') as temporary:
        context=Path(temporary)
        env={k:v for k,v in os.environ.items() if not k.startswith('GIT_')}
        for name,key in [('home','HOME'),('preferences','CFFIXED_USER_HOME'),('xdg','XDG_CONFIG_HOME'),('temporary','TMPDIR')]:
            folder=context/name;folder.mkdir(mode=0o700);env[key]=str(folder)+('/' if key=='TMPDIR' else '')
        fixture=context/'fixture';fixture.mkdir(mode=0o700)
        env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
        print('Checking literal tools '+case,flush=True)
        result=run_receiver([str(receiver),str(fixture),case],cwd=root,env=env,capture_output=True,text=True,timeout_sample=root/('build/qa/literal-tools-'+case+'.sample.txt'))
        print(result.stdout,end='');print(result.stderr,end='')
        passed=result.returncode==0 and 'PASS: literal tools '+case in result.stdout
        results.append(dict(case=case,returncode=result.returncode,passed=passed))
        (root/'build/qa/literal-tools-native-results.json').write_text(json.dumps(results,indent=2)+'\n')
        result.check_returncode()
        if not passed:raise RuntimeError('Receiver exited before final assertions: '+case)
