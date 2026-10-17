#!/usr/bin/env python3
"""Finder snapshot query reuse, native menus and owned publication family."""
import argparse, os, tempfile
from pathlib import Path
from native_receiver import build_receiver, run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append');args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='TurtleGitFinderQueries-') as temporary:
    directory=Path(temporary);fixtures=[root/'FinderSync/FinderSync.swift']
    for name in ['finder-publication-native-2026-10-13.swift','finder-publication-worker-native-2026-10-13.swift','finder-root-identity-native-2026-10-18.swift']:
        source=directory/name;source.write_text((root/'docs/qa'/name).read_text().replace('@main ', '',1));fixtures.append(source)
    fixtures.append(root/'docs/qa/finder-query-family-native-2026-10-18.swift')
    binary=build_receiver(root,fixtures,directory)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture=directory/str(index);fixture.mkdir()
        result=run_receiver([str(binary),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
        print(result.stdout,end='',flush=True);print(result.stderr,end='',flush=True);result.check_returncode()
        if 'PASS: Finder indexed query family' not in result.stdout:raise SystemExit('Missing completion marker')
