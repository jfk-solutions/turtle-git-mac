#!/usr/bin/env python3
"""Grouped primary command startup, permissions, presets and native dialogs."""
import argparse, os, tempfile
from pathlib import Path
from native_receiver import build_receiver, run_receiver
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--git',type=Path,action='append')
p.add_argument('--only',choices=['family','bare','io','network','files','maintenance','integration','patches','bisect','submodules','syncsvn','history','lfs','worktrees','mail'],action='append')
args=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-primary-commands-') as temporary:
    folder=Path(temporary)
    fixture=folder/'GitSVNFixture.swift'
    fixture_text=(root/'Tests/TurtleGitCoreTests/GitSVNFixture.swift').read_text().replace('@testable import TurtleGitCore','import TurtleGitCore')
    fixture_text=fixture_text.replace('FileManager.default.temporaryDirectory.appendingPathComponent','URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent')
    fixture_text=fixture_text.replace("command=args[offset+2:]", "command=args[offset+2:]\n        while command and command[0].startswith('-'):\n            command=command[2:] if command[0] in ('-c','-C','--git-dir','--work-tree') else command[1:]")
    fixture.write_text(fixture_text)
    receiver=build_receiver(root,[root/'docs/qa/primary-commands-native-2026-10-18.swift',root/'docs/qa/source-file-commands-native-2026-10-18.swift',root/'docs/qa/maintenance-commands-native-2026-10-18.swift',root/'docs/qa/integration-commands-native-2026-10-18.swift',root/'docs/qa/patch-commands-native-2026-10-18.swift',root/'docs/qa/bisect-commands-native-2026-10-18.swift',root/'docs/qa/submodule-commands-native-2026-10-18.swift',root/'docs/qa/sync-svn-commands-native-2026-10-18.swift',root/'docs/qa/history-commands-native-2026-10-18.swift',root/'docs/qa/lfs-commands-native-2026-10-18.swift',root/'docs/qa/worktree-commands-native-2026-10-18.swift',root/'docs/qa/mail-commands-native-2026-10-18.swift',fixture],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for case in args.only or ['family','bare','io','network','files','maintenance','integration','patches','bisect','submodules','syncsvn','history','lfs','worktrees','mail']:
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            directory=folder/(case+str(index));directory.mkdir()
            print('Checking primary command '+case+' with '+str(git),flush=True)
            result=run_receiver([str(receiver),str(directory),str(git.absolute()),case],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            marker={'family':'PASS: once-only startup','io':'PASS: command file IO family','bare':'PASS: bare command eligibility','network':'PASS: network/reference command family','files':'PASS: source file command family','maintenance':'PASS: repository maintenance command family','integration':'PASS: integration command family','patches':'PASS: patch command family','bisect':'PASS: bisect command family','submodules':'PASS: submodule command family','syncsvn':'PASS: Synchronization/SVN command family','history':'PASS: historical command family','lfs':'PASS: LFS command family','worktrees':'PASS: Worktree command family','mail':'PASS: Mail command family'}[case]
            if marker not in result.stdout:raise SystemExit('Native primary command checks did not finish')
