#!/usr/bin/env python3
"""Native repository-independent utility and local Merge startup admission."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--git',type=Path,action='append')
p.add_argument('--only',choices=['utilities','merge'],action='append')
a=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-utility-startup-') as temporary:
    directory=Path(temporary).resolve()
    receiver=build_receiver(root,[root/'docs/qa/utility-startup-native-2026-10-31.swift'],directory)
    for case in a.only or ['utilities','merge']:
        for index,git in enumerate(a.git or [Path('/usr/bin/git'),root/'build/git-runtime/Git/bin/git']):
            private=directory/(case+str(index));private.mkdir(mode=0o700)
            for name in ['fixture','home','preferences','xdg','temporary']:(private/name).mkdir(mode=0o700)
            config=private/'invalid-global.config';config.write_text('[invalid configuration\n')
            env={k:v for k,v in os.environ.items() if not k.startswith('GIT_')}
            env.update(HOME=str(private/'home'),CFFIXED_USER_HOME=str(private/'preferences'),XDG_CONFIG_HOME=str(private/'xdg'),TMPDIR=str(private/'temporary')+'/',GIT_CONFIG_GLOBAL=str(config),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'))
            print('Checking utility startup '+case+' with '+str(git),flush=True)
            result=run_receiver([str(receiver),str(private/'fixture'),str(git.absolute()),case],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: utility startup '+case not in result.stdout:raise RuntimeError('Utility receiver omitted final assertions')
