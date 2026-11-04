#!/usr/bin/env python3
"""Grouped native Add/Revert file flow, direct selections and Commit controls."""
import argparse,ast,json,os,shutil,signal,subprocess,tempfile,time
from pathlib import Path
from native_receiver import build_receiver,run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--only',choices=['flow','direct-revert','commit-commands'],action='append')
args=parser.parse_args();root=Path(__file__).resolve().parent.parent
# Keep the same exact-image + open-private-resource cleanup used by the native
# Log family; private receiver process groups are already reaped by run_receiver.
cleanup_tree=ast.parse((root/'scripts/test-log-file-drags.py').read_text())
cleanup=next(item for item in cleanup_tree.body if isinstance(item,ast.FunctionDef) and item.name=='retire_owned_helpers')
namespace=dict(os=os,signal=signal,time=time,subprocess=subprocess,Path=Path)
exec(compile(ast.Module(body=[cleanup],type_ignores=[]),'<owned Add/Revert helper cleanup>','exec'),namespace)
retire_owned_helpers=namespace['retire_owned_helpers']
def retain_failure(context, mode, index):
    failures=root/'build/qa/native-add-revert-failures';failures.mkdir(parents=True,exist_ok=True)
    evidence=Path(tempfile.mkdtemp(prefix=mode+'-'+str(index)+'-',dir=failures))
    shutil.copytree(context,evidence,dirs_exist_ok=True,symlinks=True)
    print('Retained private Add/Revert failure evidence: '+str(evidence),flush=True)

results=[]
with tempfile.TemporaryDirectory(prefix='tg-add-revert-flow-') as temporary:
    directory=Path(temporary)
    receiver=build_receiver(root,[root/'docs/qa/add-revert-file-flow-native-2026-10-17.swift',root/'docs/qa/commit-command-menu-native-2026-10-16.swift'],directory)
    for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
        git=git.absolute()
        for mode in args.only or ['flow','direct-revert','commit-commands']:
            context=directory/(str(index)+'-'+mode);context.mkdir()
            for name in ['fixture','home','preferences','temporary','xdg']:(context/name).mkdir(mode=0o700)
            config=context/'global.config';config.write_text('')
            env={key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
            env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=str(config),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',
                       HOME=str(context/'home'),CFFIXED_USER_HOME=str(context/'preferences'),TMPDIR=str(context/'temporary')+'/',XDG_CONFIG_HOME=str(context/'xdg'))
            print('Checking Add/Revert '+mode+' '+str(git),flush=True)
            passed=False
            try:
                result=run_receiver([str(receiver),str(context/'fixture'),str(git),mode],cwd=root,env=env,capture_output=True,text=True,timeout=300,timeout_sample=context/'timeout.sample.txt')
                (context/'receiver.stdout.log').write_text(result.stdout);(context/'receiver.stderr.log').write_text(result.stderr)
                print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
                marker={'flow':'PASS Add/Revert file flow:','direct-revert':'PASS direct Revert selection family','commit-commands':'PASS grouped Commit command controls'}[mode]
                passed=marker in result.stdout
                results.append(dict(git=str(git),case=mode,passed=passed,returncode=result.returncode))
                (root/'build/qa/add-revert-file-flow-native-results.json').write_text(json.dumps(results,indent=2)+'\n')
                if not passed:raise RuntimeError('Receiver exited before completion')
            except BaseException:
                retain_failure(context,mode,index)
                raise
            finally:
                try:
                    approved={str(git.resolve())}
                    selected=subprocess.run(['/usr/bin/xcrun','--find','git'],capture_output=True,text=True,timeout=10)
                    if selected.returncode==0:approved.add(str(Path(selected.stdout.strip()).resolve()))
                    needed=retire_owned_helpers(context,approved)
                    if passed and needed:raise RuntimeError('Successful Add/Revert receiver left owned helpers running')
                except BaseException:
                    retain_failure(context,mode,index)
                    raise
