#!/usr/bin/env python3
"""Grouped Browser revision selection and retained table/lifecycle checks."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--only',choices=['presentation','revision','table','lifecycle','activation'],action='append')
args=parser.parse_args();root=Path(__file__).resolve().parent.parent
cases=[('activation','browser-activation-native-2026-10-30.swift','PASS: Browser clicked-row activation','browser-activation'),('presentation','browser-presentation-native-2026-10-16.swift','PASS: Browser scoped divider','browser-presentation'),('revision','browser-revision-selection-native-2026-10-16.swift','PASS: browser revision labels','browser-revision'),('table','repository-browser-table-native-2026-10-13.swift','Repository Browser native table:','repository-browser-table'),('lifecycle','repository-browser-lifecycle-native-2026-10-13.swift','Repository Browser: retained ancestor','repository-browser')]
with tempfile.TemporaryDirectory(prefix='tg-browser-revisions-') as temporary:
    directory=Path(temporary);env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for case,source,marker,legacy in cases:
        if args.only and case not in args.only:continue
        receiver=build_receiver(root,[root/'docs/qa'/source],directory)
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture=directory/(case+str(index));fixture.mkdir()
            case_env=env.copy()
            if case=='activation':
                for name in ['home','preferences','xdg','temporary']:(fixture/name).mkdir(mode=0o700)
                case_env.update(HOME=str(fixture/'home'),CFFIXED_USER_HOME=str(fixture/'preferences'),XDG_CONFIG_HOME=str(fixture/'xdg'),TMPDIR=str(fixture/'temporary')+'/')
            result=run_receiver([str(receiver),str(fixture),str(git.absolute()),legacy],cwd=root,env=case_env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if marker not in result.stdout:raise SystemExit('Receiver exited before final assertion: '+case)
