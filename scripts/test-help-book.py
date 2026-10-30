#!/usr/bin/env python3
"""Exercise contextual native help without launching Help Viewer or a browser."""
from pathlib import Path
import argparse
import os
import json
import subprocess
import sys
import tempfile
from native_receiver import build_receiver,run_receiver
root=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app',type=Path,help='Explicit resource bundle for a private Help check; does not rebuild or substitute resources in the default packaged-app check.')
parser.add_argument('--only',choices=['contracts','native'],help='Run one affected Help family component; default runs both.')
args=parser.parse_args()
app=(args.app or root/'build/Build/Products/Debug/TurtleGitMac.app').absolute()
if args.only != 'native':
    subprocess.run([sys.executable,str(root/'scripts/test-help-index.py')],cwd=root,check=True)
if args.only == 'contracts':
    raise SystemExit(0)
subprocess.run([sys.executable,str(root/'scripts/index-help.py'),'--verify',str(app)],cwd=root,check=True)
print('Checking Help resource bundle:',app,'(explicit override; no rebuild implied)' if args.app else '(built Debug application)',flush=True)
with tempfile.TemporaryDirectory(prefix='tg-help-',dir='/tmp') as temporary:
    folder=Path(temporary);inputs=root/'build/qa/help-book-fixtures';inputs.mkdir(parents=True,exist_ok=True)
    source=inputs/'help-book-native-2026-10-15.swift';source.write_text((root/'docs/qa'/source.name).read_text())
    receiver=build_receiver(root,[source],folder)
    fixture=folder/'repo';fixture.mkdir()
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    result=run_receiver([str(receiver),str(app),str(fixture)],cwd=root,env=env,capture_output=True,text=True)
    print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
    receipts=[line.removeprefix('HELP_BOOK_COMPLETED: ') for line in result.stdout.splitlines() if line.startswith('HELP_BOOK_COMPLETED: ')]
    if len(receipts)!=1:raise SystemExit('Help receiver did not complete exactly once.')
    report=json.loads(receipts[0]);expected=[topic['id'] for topic in json.loads((root/'docs/help-topics.json').read_text())['topics']]
    bundled=report['bundledTopics'];native=report['nativeRoutes']
    if len(set(expected))!=len(expected) or sorted(bundled)!=sorted(expected):raise SystemExit('Validated bundled Help topics differ from the source catalogue.')
    if not native or len(set(native))!=len(native) or not set(native).issubset(bundled):raise SystemExit('Invalid validated native Help routes.')
    completion=f'PASS: {len(bundled)} bundled topics, {len(native)} native routes, registration/anchor and offline fallback routing, real controller/Settings Help, F1/sheets/close lifetime, built index'
    if result.stdout.splitlines().count(completion)!=1:raise SystemExit('Help receiver completion assertions were not reported exactly once.')
