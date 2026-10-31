#!/usr/bin/env python3
"""Native Cherry Pick/replay assertions with cached Debug app objects.

The full default suite still requires its SwiftPM editor. The focused Log family
uses no editor. Receivers use private repositories/preferences and hidden owners;
this does not establish physical keyboard, accessibility or signed acceptance.
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
from native_receiver import build_receiver,run_receiver

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append',help='Git to test; may be repeated (default: /usr/bin/git).')
focus=parser.add_mutually_exclusive_group()
focus.add_argument('--references-only',action='store_true',help='Run only native Rebase reference-update fixtures.')
focus.add_argument('--menus-only',action='store_true',help='Run only native Rebase revision-menu fixtures.')
focus.add_argument('--commit-selection-only',action='store_true',help='Run only native Commit visible-selection and full-index fixtures.')
focus.add_argument('--log-paths-only',action='store_true',help='Run only native Log path/filter/status-color fixtures.')
focus.add_argument('--only',choices=['log-deferred-refresh'],help='Run one complete native workflow family.')
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
products=root/'build/Build/Products/Debug'
editor=root/'.build/debug/TurtleGitMac'
if not (products/'TurtleGitCore.framework').is_dir() or (args.only is None and not editor.is_file()):
    parser.error('Build the unsigned Debug Xcode product and, for the full/default modes, the SwiftPM editor first.')
gits=args.git or [Path('/usr/bin/git')]
for git in gits:
    if not git.resolve().is_file():parser.error('Git executable does not exist.')
# Reuse the existing exact-executable plus open-private-resource cleanup policy.
cleanup_tree=ast.parse((root/'scripts/test-log-file-drags.py').read_text())
cleanup=next(item for item in cleanup_tree.body if isinstance(item,ast.FunctionDef) and item.name=='retire_owned_helpers')
namespace=dict(os=os,signal=signal,time=time,subprocess=subprocess,Path=Path)
exec(compile(ast.Module(body=[cleanup],type_ignores=[]),'<owned native Cherry Pick/Log helper cleanup>','exec'),namespace)
retire_owned_helpers=namespace['retire_owned_helpers']
generated=root/'build/qa/cherry-pick-native-sources';generated.mkdir(parents=True,exist_ok=True)
receiver=build_receiver(root,[root/'docs/qa/cherry-pick-native-receiver-2026-10-06.swift'],generated)
# Do not replace the formerly unbounded full suite with the receiver helper's
# five-minute default. Its complete assertion set has a separate three-hour cap.
timeout=240 if args.only else 3*60*60
results=[]
for index,git in enumerate(gits):
    git=git.absolute()
    with tempfile.TemporaryDirectory(prefix='turtlegit-cherry-pick-check-') as temporary:
        directory=Path(temporary)
        for name in ['home','preferences','temporary','xdg']:(directory/name).mkdir(mode=0o700)
        config=directory/'global.config';config.write_text('')
        environment={key:value for key,value in os.environ.items() if not key.startswith('GIT_') and not key.startswith('TURTLEGIT_NATIVE_')}
        environment.update(DYLD_FRAMEWORK_PATH=str(products),HOME=str(directory/'home'),CFFIXED_USER_HOME=str(directory/'preferences'),
                           TMPDIR=str(directory/'temporary')+'/',XDG_CONFIG_HOME=str(directory/'xdg'),GIT_CONFIG_GLOBAL=str(config),
                           GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',TURTLEGIT_TEST_GIT=str(git.resolve()))
        flags={'TURTLEGIT_NATIVE_REFERENCE_ONLY':args.references_only,'TURTLEGIT_NATIVE_MENUS_ONLY':args.menus_only,
               'TURTLEGIT_NATIVE_COMMIT_SELECTION_ONLY':args.commit_selection_only,'TURTLEGIT_NATIVE_LOG_PATHS_ONLY':args.log_paths_only,
               'TURTLEGIT_NATIVE_LOG_DEFERRED_REFRESH_ONLY':args.only=='log-deferred-refresh'}
        environment.update({key:'1' if enabled else '0' for key,enabled in flags.items()})
        if args.only:environment['TURTLEGIT_NATIVE_DEFERRED_ROOT']=str(directory/'repository')
        approved={str(git.resolve()),str(Path('/usr/bin/git').resolve())}
        selected=subprocess.run(['/usr/bin/xcrun','--find','git'],capture_output=True,text=True,timeout=10)
        if selected.returncode==0:approved.add(str(Path(selected.stdout.strip()).resolve()))
        if editor.is_file():approved.add(str(editor.resolve()))
        passed=False
        print('Checking native '+(args.only or 'Cherry Pick/replay selection')+' with '+str(git),flush=True)
        try:
            result=run_receiver([str(receiver)],cwd=root,env=environment,capture_output=True,text=True,timeout=timeout,timeout_sample=directory/'timeout.sample.txt')
            (directory/'receiver.stdout.log').write_text(result.stdout);(directory/'receiver.stderr.log').write_text(result.stderr)
            print(result.stdout,end='');print(result.stderr,end='')
            result.check_returncode()
            passed=args.only is None or 'PASS: Log deferred refresh family' in result.stdout
            if not passed:raise RuntimeError('Focused Log receiver exited before final assertions/cleanup')
            results.append(dict(case=args.only or 'default',git=str(git),returncode=result.returncode,passed=True,timeout_seconds=timeout))
            (root/'build/qa/cherry-pick-native-results.json').write_text(json.dumps(results,indent=2)+'\n')
        except BaseException:
            failures=root/'build/qa/native-cherry-pick-failures';failures.mkdir(parents=True,exist_ok=True)
            evidence=Path(tempfile.mkdtemp(prefix=(args.only or 'default')+'-'+str(index)+'-',dir=failures))
            shutil.copytree(directory,evidence,dirs_exist_ok=True,symlinks=True)
            print('Retained private native Cherry Pick/Log evidence: '+str(evidence),flush=True)
            raise
        finally:
            retired=retire_owned_helpers(directory,approved)
            print('Native Cherry Pick/Log owned helper cleanup verified; receiver reaping reported by native_receiver.',flush=True)
            if passed and retired:raise RuntimeError('Native receiver left owned helpers after successful assertions')
