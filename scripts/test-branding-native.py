#!/usr/bin/env python3
"""One native shared-branding/Finder-builder/About/authentication resource check."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--captures',type=Path)
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
sources=root/'build/qa/branding-native-sources';sources.mkdir(parents=True,exist_ok=True)
# Compile the real standalone authentication controller without launching its app.
# Its normal target sees Core types through target-wide imports; inject that
# same module import for this single-controller native receiver.
askpass=sources/'PromptWindow.swift'
contents='import TurtleGitCore\n'+(root/'Sources/TurtleGitGitAskpass/PromptWindow.swift').read_text()
if not askpass.is_file() or askpass.read_text()!=contents:askpass.write_text(contents)
receiver=build_receiver(root,[root/'FinderSync/FinderSync.swift',askpass,root/'docs/qa/branding-native-2026-10-19.swift'],sources)
app=root/'build/Build/Products/Debug/TurtleGitMac.app'
captures=(args.captures or root/'build/qa/branding-native-captures').absolute()
with tempfile.TemporaryDirectory(prefix='turtlegit-branding-native-') as temporary:
    folder=Path(temporary);config=folder/'global.config';config.write_text('')
    home=folder/'home';home.mkdir()
    env=dict(os.environ,HOME=str(home),CFFIXED_USER_HOME=str(home),DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=str(config),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',XDG_CONFIG_HOME=str(folder/'xdg'))
    for key in ['GIT_CONFIG_PARAMETERS','GIT_AUTHOR_NAME','GIT_AUTHOR_EMAIL','GIT_COMMITTER_NAME','GIT_COMMITTER_EMAIL']:env.pop(key,None)
    result=run_receiver([str(receiver),str(folder),str(app),str(captures)],cwd=root,env=env,capture_output=True,text=True,timeout_sample=folder/'timeout.sample.txt')
    print(result.stdout,end='',flush=True);print(result.stderr,end='',flush=True);result.check_returncode()
    if 'PASS: native custom branding/' not in result.stdout:raise SystemExit('Branding receiver exited before completion')
