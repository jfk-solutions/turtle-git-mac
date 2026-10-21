#!/usr/bin/env python3
"""Grouped native Export archive formats, chooser options, captured scope and owned lifetime."""
import argparse,os,tempfile,json,tarfile,zipfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--git',type=Path,action='append')
p.add_argument('--only',choices=['formats','chooser','ownership'],action='append')
p.add_argument('--captures',type=Path)
a=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-export-formats-') as temporary:
    directory=Path(temporary);receiver=build_receiver(root,[root/'docs/qa/export-archive-formats-native-2026-10-21.swift'],directory)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for key in ['GIT_CONFIG_PARAMETERS','GIT_AUTHOR_NAME','GIT_AUTHOR_EMAIL','GIT_AUTHOR_DATE','GIT_COMMITTER_NAME','GIT_COMMITTER_EMAIL','GIT_COMMITTER_DATE']:env.pop(key,None)
    if a.captures:a.captures.mkdir(parents=True,exist_ok=True);env['TURTLEGIT_EXPORT_FORMATS_CAPTURES']=str(a.captures.absolute())
    for case in a.only or ['formats','chooser','ownership']:
        for index,git in enumerate(a.git or [Path('/usr/bin/git')]):
            directory_case=directory/(case+str(index));directory_case.mkdir()
            result=run_receiver([str(receiver),str(directory_case),str(git.absolute()),case],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: Export formats '+case not in result.stdout:raise SystemExit('Receiver exited before final assertions: '+case)

            manifest=directory_case/'archive-oracles.json'
            if manifest.exists():
                for oracle in json.loads(manifest.read_text()):
                    archive=Path(oracle['path'])
                    if zipfile.is_zipfile(archive):
                        with zipfile.ZipFile(archive) as opened: actual={name:opened.read(name).decode('utf-8') for name in opened.namelist() if not name.endswith('/')}
                    else:
                        with tarfile.open(archive) as opened: actual={item.name:opened.extractfile(item).read().decode('utf-8') for item in opened.getmembers() if item.isfile()}
                    if actual != oracle['members']: raise SystemExit('Actual exported archive members differ: '+str(archive)+' '+repr(actual))
