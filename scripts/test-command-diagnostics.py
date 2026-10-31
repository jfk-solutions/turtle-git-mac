#!/usr/bin/env python3
"""Private offscreen native command preview/admission and settings lifecycle."""
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-command-diagnostics-') as temporary:
    directory=Path(temporary).resolve()
    receiver=build_receiver(root,[root/'docs/qa/command-diagnostics-native-2026-10-31.swift'],directory)
    for name in ['fixture','home','preferences','xdg','temporary']:(directory/name).mkdir(mode=0o700)
    config=directory/'global.config';config.write_text('')
    env={k:v for k,v in os.environ.items() if not k.startswith('GIT_')}
    env.update(HOME=str(directory/'home'),CFFIXED_USER_HOME=str(directory/'preferences'),XDG_CONFIG_HOME=str(directory/'xdg'),TMPDIR=str(directory/'temporary')+'/',GIT_CONFIG_GLOBAL=str(config),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'))
    result=run_receiver([str(receiver),str(directory/'fixture')],cwd=root,env=env,capture_output=True,text=True)
    print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
    if 'PASS: native command diagnostics' not in result.stdout:raise RuntimeError('Diagnostic fixture omitted final assertions')
