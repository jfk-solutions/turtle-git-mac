#!/usr/bin/env python3
"""Grouped captured annotation menus and retained Blame menu/editor workflows."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--captures',type=Path)
parser.add_argument('--only',choices=['commands','source-menu','menus','editor'],action='append')
args=parser.parse_args();root=Path(__file__).resolve().parent.parent
cases=[('commands','blame-command-family-native-2026-10-16.swift','PASS: Blame command family','blame-commands'),('source-menu','blame-source-menu-native-2026-10-16.swift','PASS: native Blame source captured','blame-source-menu'),('menus','blame-menu-native-2026-10-13.swift','Blame menus:','blame-menus'),('editor','blame-source-editor-native-2026-10-13.swift','Blame native source:','blame-source')]
with tempfile.TemporaryDirectory(prefix='tg-blame-source-menu-') as temporary:
    directory=Path(temporary);env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for case,source,marker,legacy in cases:
        if args.only and case not in args.only:continue
        receiver=build_receiver(root,[root/'docs/qa'/source],directory)
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture=directory/(case+str(index));fixture.mkdir()
            env.pop('TURTLEGIT_BLAME_COMMAND_CAPTURE',None)
            if args.captures and case=='commands' and index==0:
                args.captures.mkdir(parents=True,exist_ok=True);env['TURTLEGIT_BLAME_COMMAND_CAPTURE']=str(args.captures.absolute())
            result=run_receiver([str(receiver),str(fixture),str(git.absolute()),legacy],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if marker not in result.stdout:raise SystemExit('Receiver exited before final assertion: '+case)
