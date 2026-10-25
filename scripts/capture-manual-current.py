#!/usr/bin/env python3
"""Capture actual Log/Commit light and dark windows from current Debug objects."""
import hashlib,json,os,struct,tempfile,shutil,subprocess
from pathlib import Path
from native_receiver import build_receiver,run_receiver
root=Path(__file__).resolve().parent.parent
out=root/'build/qa/manual-current-captures-2026-10-25';out.mkdir(parents=True,exist_ok=True)
gen=out/'sources';gen.mkdir(exist_ok=True)
receiver=build_receiver(root,[root/'docs/qa/manual-current-captures-2026-10-25.swift'],gen)
with tempfile.TemporaryDirectory(prefix='turtlegit-manual-capture-') as private:
    context=Path(private).resolve()
    for name in ['home','preferences','tmp','xdg']:(context/name).mkdir(mode=0o700)
    env={k:v for k,v in os.environ.items() if not k.startswith('GIT_')}
    env.update(HOME=str(context/'home'),CFFIXED_USER_HOME=str(context/'preferences'),TMPDIR=str(context/'tmp')+'/',XDG_CONFIG_HOME=str(context/'xdg'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),TURTLEGIT_PREVIEW_CAPTURE_DIR=str(out))
    result=run_receiver([str(receiver),'unused','/usr/bin/git'],cwd=root,env=env,capture_output=True,text=True,timeout=120)
    (out/'stdout.txt').write_text(result.stdout);(out/'stderr.txt').write_text(result.stderr)
    print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
    if 'Captured four real current Commit/Log windows' not in result.stdout:raise RuntimeError('Native capture did not finish')
manifest={'method':'ScreenCaptureKit desktopIndependentWindow; actual native windows offscreen, original PNG bytes','repository':'Synthetic offline Harbor with branch merge, staged/unstaged files and draft; fixture commits only before capture baseline','preferences':'private suite removed; private HOME/CFFIXED_USER_HOME env','network':False,'owned_receiver_reaped':True,'assets':[]}
for kind in ['log','commit']:
    for theme in ['light','dark']:
        name=f'mac-{kind}-{theme}-2026-10-25.png';source=out/name;data=source.read_bytes();width,height=struct.unpack('>II',data[16:24]);target=root/'docs/site/assets'/name;shutil.copyfile(source,target)
        manifest['assets'].append(dict(path=str(target.relative_to(root)),raw_path=str(source.relative_to(root)),width=width,height=height,bytes=len(data),sha256=hashlib.sha256(data).hexdigest()))
manifest['stdout_sha256']=hashlib.sha256((out/'stdout.txt').read_bytes()).hexdigest();manifest['stderr_sha256']=hashlib.sha256((out/'stderr.txt').read_bytes()).hexdigest()
(root/'docs/qa/manual-current-captures-2026-10-25.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps(manifest,indent=2))
