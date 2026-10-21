#!/usr/bin/env python3
"""Grouped native Blame history cells, column ownership and deliberate captures."""
import argparse
import json
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',action='append',type=Path)
parser.add_argument('--only',action='append',choices=['presentation','ownership','captures'])
parser.add_argument('--capture-dir',type=Path)
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
sources=root/'build/qa/blame-history-presentation-native-sources';sources.mkdir(parents=True,exist_ok=True)
receiver=build_receiver(root,[root/'docs/qa/blame-history-presentation-native-2026-10-21.swift'],sources)
results=[]
cases=args.only or ['presentation','ownership']
if args.capture_dir:
    args.capture_dir=args.capture_dir.absolute();args.capture_dir.mkdir(parents=True,exist_ok=True)
    if not args.only: cases=cases+['captures']
if 'captures' in cases and not args.capture_dir: parser.error('captures requires --capture-dir')
for git in args.git or [Path('/usr/bin/git'),root/'build/git-runtime/Git/bin/git']:
    for case in cases:
        if case=='captures' and git.absolute()!=Path('/usr/bin/git'): continue
        with tempfile.TemporaryDirectory(prefix='turtlegit-blame-history-'+case+'-') as temporary:
            base=Path(temporary);scratch=base/'temporary';scratch.mkdir(mode=0o700)
            config=base/'global.config';config.write_text('')
            environment=dict(os.environ,TMPDIR=str(scratch)+'/',DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=str(config),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',XDG_CONFIG_HOME=str(base/'xdg'))
            for key in ['GIT_CONFIG_PARAMETERS','GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_COMMON_DIR','GIT_AUTHOR_NAME','GIT_AUTHOR_EMAIL','GIT_AUTHOR_DATE','GIT_COMMITTER_NAME','GIT_COMMITTER_EMAIL','GIT_COMMITTER_DATE']: environment.pop(key,None)
            arguments=[str(receiver),str(base),str(git.absolute()),case]
            if case=='captures':arguments.append(str(args.capture_dir))
            result=run_receiver(arguments,cwd=root,env=environment,capture_output=True,text=True,timeout_sample=base/'timeout.sample.txt')
            print(result.stdout,end='');print(result.stderr,end='')
            results.append(dict(git=str(git.absolute()),case=case,returncode=result.returncode,passed=result.returncode==0 and 'PASS: Blame history presentation '+case in result.stdout))
            (root/'build/qa/blame-history-presentation-native-results.json').write_text(json.dumps(results,indent=2)+'\n')
            result.check_returncode()
            if not results[-1]['passed']:raise SystemExit('Blame history receiver exited before completion')
