#!/usr/bin/env python3
"""Grouped Log document handoff and retained exact file-action checks."""
import argparse, os, tempfile
from pathlib import Path
from native_receiver import build_receiver, run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append');parser.add_argument('--only',choices=['open','files'],action='append')
args=parser.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='TurtleGitLogOpen-') as temporary:
    directory=Path(temporary);env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for name,source,marker in [('open','log-document-open-native-2026-10-17.swift','PASS: Log document Open family'),('files','log-file-identities-native-2026-10-17.swift','PASS Log file identities:')]:
        if args.only and name not in args.only:continue
        receiver=build_receiver(root,[root/'docs/qa'/source],directory)
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture=directory/(name+str(index));fixture.mkdir()
            result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='',flush=True);print(result.stderr,end='',flush=True);result.check_returncode()
            if marker not in result.stdout:raise SystemExit('Missing completion marker: '+name)
