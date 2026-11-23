#!/usr/bin/env python3
"""Grouped real Log status operands, historical boundaries and owner retirement.

Reuses the current Debug native-receiver cache; does not build the application.
All native windows, repositories, preferences, configuration and pasteboards are
private. Exact owned helpers are retired on success, failure and timeout.
"""
import argparse
import ast
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
from native_receiver import build_receiver, run_receiver

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--only',choices=('operands','rename','historical','ownership'),action='append')
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
generated=root/'build/qa/log-working-comparison-operands-sources'
generated.mkdir(parents=True,exist_ok=True)
receiver=build_receiver(root,[root/'docs/qa/log-primary-activation-native-2026-11-22.swift',
                              root/'docs/qa/log-working-comparison-operands-native-2026-11-23.swift'],generated)
tree=ast.parse((root/'scripts/test-editor-appearance.py').read_text())
definition=next(item for item in tree.body if isinstance(item,ast.FunctionDef) and item.name=='retire_owned_helpers')
exec(compile(ast.Module(body=[definition],type_ignores=[]),'<Log operand exact helper cleanup>','exec'))
results=[]
for case in args.only or ['operands','rename','historical','ownership']:
    for index,git in enumerate(args.git or [Path('/usr/bin/git'),root/'build/git-runtime/Git/bin/git']):
        git=git.absolute()
        if not git.is_file():parser.error('Git executable missing: '+str(git))
        with tempfile.TemporaryDirectory(prefix='turtlegit-log-operands-'+case+'-') as temporary:
            context=Path(temporary)
            for name in ('fixture','preferences','home','temporary','xdg'):(context/name).mkdir(mode=0o700)
            config=context/'global.config';config.write_text('')
            environment={key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
            environment.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),
                               GIT_CONFIG_GLOBAL=str(config),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',GIT_OPTIONAL_LOCKS='0',
                               HOME=str(context/'home'),CFFIXED_USER_HOME=str(context/'preferences'),
                               TMPDIR=str(context/'temporary')+'/',XDG_CONFIG_HOME=str(context/'xdg'))
            approved={str(git.resolve())}
            selected=subprocess.run(['/usr/bin/xcrun','--find','git'],capture_output=True,text=True,timeout=10)
            if selected.returncode==0:approved.add(str(Path(selected.stdout.strip()).resolve()))
            row={'case':case,'git':str(git),'status':'running'};started=time.monotonic();passed=False
            print('Checking Log working comparison '+case+' with '+str(git),flush=True)
            try:
                result=run_receiver([str(receiver),str(context/'fixture'),str(git),case],cwd=root,env=environment,
                                    capture_output=True,text=True,timeout=240,timeout_sample=context/'timeout.sample.txt')
                print(result.stdout,end='');print(result.stderr,end='');row['exit_code']=result.returncode
                result.check_returncode()
                if 'PASS: Log working comparison operands '+case not in result.stdout:
                    raise RuntimeError('Log operand receiver exited before behavioral and owned cleanup completion')
                passed=True;row['status']='passed'
            except BaseException as error:
                row.update(status='failed',error=str(error))
                evidence=Path(tempfile.mkdtemp(prefix='log-operands-failed-'+case+'-'+str(index)+'-',dir=root/'build/qa'))
                shutil.copytree(context,evidence,dirs_exist_ok=True,symlinks=True)
                for name in ('stdout','stderr'):
                    value=getattr(error,name,None)
                    if value is not None:(evidence/(name+'.log')).write_text(value.decode('utf8',errors='replace') if isinstance(value,bytes) else str(value))
                print('Retained private operand failure evidence: '+str(evidence),flush=True)
                raise
            finally:
                try:
                    row['fallback_helper_cleanup']=retire_owned_helpers(context,approved)
                    if passed and row['fallback_helper_cleanup']:raise RuntimeError('Log operand receiver leaked an owned helper')
                except BaseException as error:
                    row.update(status='failed',cleanup_error=str(error));raise
                finally:
                    row['elapsed_seconds']=round(time.monotonic()-started,3);results.append(row)
                    (root/'build/qa/log-working-comparison-operands-results.json').write_text(json.dumps({'cases':results},indent=2)+'\n')
