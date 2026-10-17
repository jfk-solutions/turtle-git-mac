#!/usr/bin/env python3
"""Grouped native SVN source forms, captured submission and retained workflows."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--captures',type=Path)
parser.add_argument('--source-only',action='store_true',help='CI retains the existing workflow receiver in the reference group.')
args=parser.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-svn-source-') as temporary:
    folder=Path(temporary)
    fixture=folder/'GitSVNFixture.swift'
    text=(root/'Tests/TurtleGitCoreTests/GitSVNFixture.swift').read_text().replace('@testable import TurtleGitCore','import TurtleGitCore')
    text=text.replace('FileManager.default.temporaryDirectory.appendingPathComponent','URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent')
    # Preserve actual argv; the injected SVN transport must skip global Git options.
    text=text.replace("command=args[offset+2:]", "command=args[offset+2:]\n        while command and command[0].startswith('-'):\n            command=command[2:] if command[0] in ('-c','-C','--git-dir','--work-tree') else command[1:]")
    fixture.write_text(text)
    receiver=build_receiver(root,[root/'docs/qa/svn-source-native-2026-10-17.swift',root/'docs/qa/svn-native-2026-10-12.swift',fixture],folder)
    env=os.environ.copy();env['TURTLEGIT_SVN_SOURCE_ONLY']='1' if args.source_only else '0';env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
        private=folder/str(index);private.mkdir();env.pop('TURTLEGIT_SVN_SOURCE_CAPTURE',None)
        if args.captures and index==0:
            args.captures.mkdir(parents=True,exist_ok=True);env['TURTLEGIT_SVN_SOURCE_CAPTURE']=str(args.captures.absolute())
        print('Checking SVN source/workflow family with '+str(git),flush=True)
        result=run_receiver([str(receiver),str(private),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if 'PASS: SVN source/workflow family' not in result.stdout:raise SystemExit('SVN receiver exited before completion.')
