#!/usr/bin/env python3
"""Grouped native command completion policy, ownership and delayed handoffs."""
import argparse
import os
import tempfile
from pathlib import Path
from native_receiver import build_receiver, run_receiver

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--only',choices=['routing','a','b'],action='append')
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-command-progress-') as temporary:
    folder=Path(temporary)
    sources=[root/'docs/qa'/name for name in [
        'command-progress-native-2026-10-28.swift',
        'command-progress-group-a-native-2026-10-28.swift',
        'command-progress-group-b-native-2026-10-28.swift']]
    receiver=build_receiver(root,sources,folder)
    for case in args.only or ['routing','a','b']:
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            directory=folder/(case+str(index));directory.mkdir()
            home=directory/'home';home.mkdir()
            env=os.environ.copy()
            env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),
                       HOME=str(home),XDG_CONFIG_HOME=str(home),
                       GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
            print('Checking command progress '+case+' with '+str(git),flush=True)
            result=run_receiver([str(receiver),str(directory),str(git.absolute()),case],
                                cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: command progress '+case+';' not in result.stdout:
                raise SystemExit('Command progress verification did not finish')
