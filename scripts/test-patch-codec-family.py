#!/usr/bin/env python3
"""Connected legacy patch preview/recovery/application and retained native consumers."""
import argparse,os,tempfile,subprocess,sys
from pathlib import Path
from native_receiver import build_receiver,run_receiver
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--git',type=Path,action='append');p.add_argument('--captures',type=Path);p.add_argument('--only',choices=['codec','retained'],action='append');a=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-patch-codecs-') as temporary:
    if not a.only or 'codec' in a.only:
        folder=Path(temporary);receiver=build_receiver(root,[root/'docs/qa/patch-codec-family-native-2026-10-17.swift'],folder)
        env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
        for index,git in enumerate(a.git or [Path('/usr/bin/git')]):
            fixture=folder/str(index);fixture.mkdir();current=env.copy()
            if a.captures and index==0:a.captures.mkdir(parents=True,exist_ok=True);current['TURTLEGIT_PATCH_CODEC_CAPTURE']=str(a.captures.absolute())
            print('Checking patch codec '+str(git),flush=True)
            result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=current,capture_output=True,text=True)
            print(result.stdout,end='',flush=True);print(result.stderr,end='',flush=True);result.check_returncode()
            if 'PASS patch codec family:' not in result.stdout:raise SystemExit('Patch codec receiver exited before completion')
    if not a.only or 'retained' in a.only:
        command=[sys.executable,str(root/'scripts/test-patch-file-panel.py'),'--only','recovery','--only','special','--only','panel']
        for git in a.git or [Path('/usr/bin/git')]:command += ['--git',str(git)]
        subprocess.run(command,cwd=root,check=True)
