#!/usr/bin/env python3
"""Browser historical Save/Open ownership, source path field and retained presentation."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
cases=[('source','browser-file-actions-native-2026-10-17.swift','PASS Browser file actions:'),('presentation','browser-presentation-native-2026-10-16.swift','PASS: Browser scoped divider')]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--git',type=Path,action='append');p.add_argument('--only',choices=[x[0] for x in cases],action='append');p.add_argument('--captures',type=Path);args=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-browser-files-') as temporary:
    folder=Path(temporary)
    for name,source,marker in cases:
        if args.only and name not in args.only:continue
        receiver=build_receiver(root,[root/'docs/qa'/source],folder)
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture=folder/(name+str(index));fixture.mkdir();global_config=fixture/'global.config';global_config.write_text('')
            env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=str(global_config),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',XDG_CONFIG_HOME=str(fixture/'xdg'))
            env.pop('TURTLEGIT_BROWSER_FILES_CAPTURE',None)
            if args.captures and name=='source' and index==0:env['TURTLEGIT_BROWSER_FILES_CAPTURE']=str(args.captures.absolute())
            print('Checking Browser '+name+' with '+str(git),flush=True)
            result=run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if marker not in result.stdout:raise SystemExit('Receiver did not finish: '+name)
