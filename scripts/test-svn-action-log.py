#!/usr/bin/env python3
"""Native SVN progress stages, persistent output and owned cancellation."""
import argparse
import os
import tempfile
from pathlib import Path
from native_receiver import build_receiver, run_receiver

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-svn-action-log-') as temporary:
    folder=Path(temporary)
    fixture=folder/'GitSVNFixture.swift'
    text=(root/'Tests/TurtleGitCoreTests/GitSVNFixture.swift').read_text().replace('@testable import TurtleGitCore','import TurtleGitCore')
    text=text.replace('FileManager.default.temporaryDirectory.appendingPathComponent','URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent')
    text=text.replace("command=args[offset+2:]", "command=args[offset+2:]\n        while command and command[0].startswith('-'):\n            command=command[2:] if command[0] in ('-c','-C','--git-dir','--work-tree') else command[1:]")
    fixture.write_text(text)
    receiver=build_receiver(root,[root/'docs/qa/svn-action-log-native-2026-10-28.swift',fixture],folder)
    for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
        directory=folder/str(index);directory.mkdir()
        home=directory/'home';home.mkdir()
        env=os.environ.copy()
        env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),HOME=str(home),
                   XDG_CONFIG_HOME=str(home),GIT_CONFIG_GLOBAL=os.devnull,
                   GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
        print('Checking SVN Action log with '+str(git),flush=True)
        result=run_receiver([str(receiver),str(directory),str(git.absolute())],cwd=root,
                            env=env,capture_output=True,text=True)
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if 'PASS: SVN distinct stage Action logs' not in result.stdout:
            raise SystemExit('SVN Action log verification did not finish')
