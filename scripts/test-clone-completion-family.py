#!/usr/bin/env python3
"""Grouped Clone completion/history, retained progress/stream and creation ownership."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
cases=[('handoffs','repository-handoffs-native-2026-10-18.swift','PASS: repository handoff family:'),('completion','clone-completion-native-2026-10-16.swift','PASS Clone completion:'),('progress','clone-progress-native-2026-10-08.swift','Clone: actual shallow'),('stream','clone-stream-native-2026-10-08.swift','Clone streaming:'),('ownership','repository-creation-owned-native-2026-10-14.swift','PASS: owned Clone source/destination')]
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--git',type=Path,action='append');parser.add_argument('--only',choices=[case[0] for case in cases],action='append');args=parser.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-clone-completion-') as temporary:
    folder=Path(temporary);env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for case,source,marker in cases:
        if args.only and case not in args.only:continue
        receiver=build_receiver(root,[root/'docs/qa'/source],folder)
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            directory=folder/(case+str(index));directory.mkdir();print('Checking Clone '+case+' with '+str(git),flush=True)
            result=run_receiver([str(receiver),str(directory),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if marker not in result.stdout:raise SystemExit('Receiver did not reach final assertions: '+case)
