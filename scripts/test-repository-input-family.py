#!/usr/bin/env python3
"""Grouped Clone/Submodule Add input defaults, histories, pickers and retained transports."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
cases=[('inputs','submodule-add-inputs-native-2026-10-17.swift','PASS Submodule Add inputs:'),('clone','clone-completion-native-2026-10-16.swift','PASS Clone completion:'),('ssh','ssh-coordinator-native-2026-10-09.swift','PASS native encrypted-key prompt/retry/dedup')]
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--git',type=Path,action='append');parser.add_argument('--only',choices=[c[0] for c in cases],action='append');parser.add_argument('--captures',type=Path);args=parser.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-repository-inputs-') as temporary:
    folder=Path(temporary);env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for case,source,marker in cases:
        if args.only and case not in args.only:continue
        receiver=build_receiver(root,[root/'docs/qa'/source],folder)
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            env.pop('TURTLEGIT_INPUT_CAPTURE',None)
            if args.captures and case=='inputs' and index==0:env['TURTLEGIT_INPUT_CAPTURE']=str(args.captures.absolute())
            directory=folder/(case+str(index));directory.mkdir();print('Checking repository inputs '+case+' with '+str(git),flush=True)
            command=[str(receiver),str(directory),str(git.absolute())]
            if case=='ssh':command.append(str(root/'build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/SSHAskpass/TurtleGitSSHAskpass'))
            result=run_receiver(command,cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if marker not in result.stdout:raise SystemExit('Receiver did not reach final assertions: '+case)
