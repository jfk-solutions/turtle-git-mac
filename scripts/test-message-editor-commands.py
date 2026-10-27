#!/usr/bin/env python3
"""Grouped actual message-editor line commands and transient zoom, with owned native cleanup."""
import argparse
import json
import os
from pathlib import Path
import shutil
import tempfile
from native_receiver import build_receiver, run_receiver


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--git',type=Path,action='append')
    parser.add_argument('--only',choices=['commit','merge','project','notes','description','integration'],action='append',help='Focused retry after an actual affected failure.')
    parser.add_argument('--report',type=Path)
    parser.add_argument('--timeout',type=float,default=180,help='Owned receiver deadline; focused failure diagnostics may use a shorter bound.')
    args=parser.parse_args()
    root=Path(__file__).resolve().parent.parent
    folder=root/'build/qa/message-editor-commands-native';folder.mkdir(parents=True,exist_ok=True)
    receiver=build_receiver(root,[root/'docs/qa/message-editor-commands-native-2026-10-27.swift'],folder)
    results=[]
    report=args.report or root/'build/qa/message-editor-commands-native-results.json'
    for index,git in enumerate(args.git or [Path('/usr/bin/git'),root/'build/git-runtime/Git/bin/git']):
        with tempfile.TemporaryDirectory(prefix='turtlegit-message-commands-') as temporary:
            context=Path(temporary)
            for name in ['repository','preferences','home','xdg','temporary']:(context/name).mkdir(mode=0o700)
            config=context/'global.config';config.write_text('')
            environment={key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
            environment.update(GIT_CONFIG_GLOBAL=str(config),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',
                HOME=str(context/'home'),CFFIXED_USER_HOME=str(context/'preferences'),XDG_CONFIG_HOME=str(context/'xdg'),
                TMPDIR=str(context/'temporary')+'/',DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'))
            environment.pop('TURTLEGIT_MESSAGE_COMMAND_CASES',None)
            if args.only:environment['TURTLEGIT_MESSAGE_COMMAND_CASES']=','.join(args.only)
            print('Checking shared message commands/zoom with '+str(git),flush=True)
            receipt=dict(git=str(git),cases=args.only or ['commit','merge','project','notes','description','integration'],passed=False)
            stdout=stderr=''
            try:
                result=run_receiver([str(receiver),str(context/'repository'),str(git.absolute())],cwd=root,env=environment,capture_output=True,text=True,timeout=args.timeout,timeout_sample=context/'timeout.sample.txt')
                stdout,stderr=result.stdout,result.stderr
                print(stdout,end='');print(stderr,end='')
                receipt.update(returncode=result.returncode)
                result.check_returncode()
                if 'PASS: shared message editor commands and zoom' not in stdout:raise RuntimeError('Message command receiver exited before completed cleanup')
                receipt['passed']=True
            except BaseException as error:
                receipt['failure']=str(error)
                for key in ['stdout','stderr']:
                    captured=getattr(error,key,None)
                    if captured:
                        if isinstance(captured,bytes):captured=captured.decode(errors='replace')
                        if key=='stdout':stdout=captured
                        else:stderr=captured
                evidence=Path(tempfile.mkdtemp(prefix='message-editor-commands-failed-'+str(index)+'-',dir=root/'build/qa'))
                shutil.copytree(context,evidence/'context')
                (evidence/'stdout.log').write_text(stdout);(evidence/'stderr.log').write_text(stderr)
                receipt['evidence']=str(evidence)
                (evidence/'failure.json').write_text(json.dumps(receipt,indent=2)+'\n')
                print('Retained failed receiver evidence: '+str(evidence),flush=True)
                raise
            finally:
                results.append(receipt)
                report.parent.mkdir(parents=True,exist_ok=True);report.write_text(json.dumps(results,indent=2)+'\n')


if __name__=='__main__':main()
