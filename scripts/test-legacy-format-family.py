#!/usr/bin/env python3
"""Configured legacy formats and retained native Encoding consumers."""
import argparse,os,tempfile,subprocess,sys
from pathlib import Path
from native_receiver import build_receiver,run_receiver
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--captures',type=Path);p.add_argument('--only',choices=['legacy','retained'],action='append');a=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-legacy-formats-') as temporary:
    if not a.only or 'legacy' in a.only:
        folder=Path(temporary);receiver=build_receiver(root,[root/'docs/qa/legacy-format-family-native-2026-10-17.swift'],folder)
        env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
        if a.captures:a.captures.mkdir(parents=True,exist_ok=True);env['TURTLEGIT_LEGACY_CAPTURE']=str(a.captures.absolute())
        result=run_receiver([str(receiver),str(folder)],cwd=root,env=env,capture_output=True,text=True)
        print(result.stdout,end='',flush=True);print(result.stderr,end='',flush=True);result.check_returncode()
        if 'PASS legacy format family:' not in result.stdout:raise SystemExit('Legacy receiver exited before completion')
    if not a.only or 'retained' in a.only:
        subprocess.run([sys.executable,str(root/'scripts/test-merge-format-source.py')],cwd=root,check=True)
