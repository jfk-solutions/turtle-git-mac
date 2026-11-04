#!/usr/bin/env python3
"""Grouped primary file-menu workflows using current cached Debug app objects."""
import argparse,ast,json,os,shutil,signal,subprocess,tempfile,time
from pathlib import Path
from native_receiver import build_receiver,run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--only',choices=['primary-file-menus-2026-10-16','working-tree-file-menu','working-tree-scope'],action='append')
args=parser.parse_args();root=Path(__file__).resolve().parent.parent
# Reuse exact-executable plus open-private-resource ownership. Never terminate
# an application merely because its command line mentions this repository.
cleanup_tree=ast.parse((root/'scripts/test-log-file-drags.py').read_text())
cleanup=next(item for item in cleanup_tree.body if isinstance(item,ast.FunctionDef) and item.name=='retire_owned_helpers')
namespace=dict(os=os,signal=signal,time=time,subprocess=subprocess,Path=Path)
exec(compile(ast.Module(body=[cleanup],type_ignores=[]),'<owned primary file-menu helpers>','exec'),namespace)
retire_owned_helpers=namespace['retire_owned_helpers']
cases=[('primary-file-menus-2026-10-16','docs/qa/primary-file-menus-native-2026-10-16.swift','PASS: primary marked-row'),('working-tree-file-menu','docs/qa/working-tree-file-menu-native-2026-10-14.swift','Working Tree menus:'),('working-tree-scope','docs/qa/working-tree-scope-native-2026-10-14.swift','Working Tree scope')]
results=[]
with tempfile.TemporaryDirectory(prefix='tg-primary-menus-') as temporary:
    folder=Path(temporary)
    for name,source,passing in cases:
        if args.only and name not in args.only:continue
        build=folder/name;build.mkdir();receiver=build_receiver(root,[root/source],build)
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            git=git.absolute();context=build/str(index);context.mkdir()
            for directory in ['fixture','preferences','temporary','xdg']:(context/directory).mkdir(mode=0o700)
            config=context/'global.config';config.write_text('')
            env={key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
            env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=str(config),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',
                       CFFIXED_USER_HOME=str(context/'preferences'),TMPDIR=str(context/'temporary')+'/',XDG_CONFIG_HOME=str(context/'xdg'))
            passed=False;retained=False
            def retain():
                target=root/'build/qa/native-primary-file-menu-failures';target.mkdir(parents=True,exist_ok=True)
                evidence=Path(tempfile.mkdtemp(prefix=name+'-'+str(index)+'-',dir=target))
                shutil.copytree(context,evidence,dirs_exist_ok=True,symlinks=True)
                print('Retained private primary file-menu evidence: '+str(evidence),flush=True)
            print('Checking primary file-menu '+name+' with '+str(git),flush=True)
            try:
                result=run_receiver([str(receiver),str(context/'fixture'),str(git)],cwd=root,env=env,capture_output=True,text=True,timeout=300,timeout_sample=context/'timeout.sample.txt')
                (context/'receiver.stdout.log').write_text(result.stdout);(context/'receiver.stderr.log').write_text(result.stderr)
                print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
                if passing not in result.stdout:raise RuntimeError('Receiver exited before final assertion: '+name)
                passed=True;results.append(dict(case=name,git=str(git),exit_code=result.returncode,passed=True))
                (root/'build/qa/primary-file-menu-native-results.json').write_text(json.dumps(results,indent=2)+'\n')
            except BaseException:
                retain();retained=True;raise
            finally:
                try:
                    approved={str(git.resolve()),str(Path('/usr/bin/git').resolve())}
                    selected=subprocess.run(['/usr/bin/xcrun','--find','git'],capture_output=True,text=True,timeout=10)
                    if selected.returncode==0:approved.add(str(Path(selected.stdout.strip()).resolve()))
                    needed=retire_owned_helpers(context,approved)
                    if passed and needed:raise RuntimeError('Successful primary file-menu receiver left owned helpers')
                except BaseException:
                    if not retained:retain()
                    raise
