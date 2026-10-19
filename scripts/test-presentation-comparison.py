#!/usr/bin/env python3
"""Grouped native PowerPoint automation contract, routing, review and lifecycle."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--captures',type=Path)
parser.add_argument('--only',choices=['automation','review','routing','lifecycle'],action='append')
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
sources=root/'build/qa/presentation-comparison-sources'
sources.mkdir(parents=True,exist_ok=True)
receiver=build_receiver(root,[root/'docs/qa/presentation-comparison-native-2026-10-20.swift',root/'docs/qa/powerpoint-automation-native-2026-10-20.swift'],sources)
with tempfile.TemporaryDirectory(prefix='turtlegit-presentation-review-') as temporary:
    for case in args.only or ['automation','review','routing','lifecycle']:
        directory=Path(temporary)/case;directory.mkdir()
        env=dict(os.environ,DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),TURTLEGIT_PRESENTATION_CASE=case)
        private_tmp=directory/'temporary';private_tmp.mkdir(mode=0o700);env['TMPDIR']=str(private_tmp)
        if args.captures and case=='review':env['TURTLEGIT_PRESENTATION_CAPTURES']=str(args.captures.absolute())
        print('Checking presentation '+case,flush=True)
        result=run_receiver([str(receiver),str(directory)],cwd=root,env=env,capture_output=True,text=True,timeout_sample=directory/'timeout.sample.txt')
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if 'PASS: presentation native review completed' not in result.stdout:raise SystemExit('Presentation receiver exited before completion: '+case)
