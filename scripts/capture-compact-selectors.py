#!/usr/bin/env python3
"""Capture actual Log/Commit light and dark windows from current Debug objects."""
import hashlib,json,os,struct,tempfile,shutil,subprocess
from pathlib import Path
from native_receiver import build_receiver,run_receiver
root=Path(__file__).resolve().parent.parent
clean=Path('/Users/jkuehner/.codex/worktrees/finder-headless-registration/tortoise-git-mac')
out=root/'build/qa/compact-selector-captures-2026-10-25';out.mkdir(parents=True,exist_ok=True)
gen=out/'sources';gen.mkdir(exist_ok=True)
receiver=build_receiver(clean,[root/'docs/qa/compact-selector-captures-2026-10-25.swift'],gen)
with tempfile.TemporaryDirectory(prefix='turtlegit-manual-capture-') as private:
    context=Path(private).resolve()
    for name in ['home','preferences','tmp','xdg']:(context/name).mkdir(mode=0o700)
    env={k:v for k,v in os.environ.items() if not k.startswith('GIT_')}
    env.update(HOME=str(context/'home'),CFFIXED_USER_HOME=str(context/'preferences'),TMPDIR=str(context/'tmp')+'/',XDG_CONFIG_HOME=str(context/'xdg'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',DYLD_FRAMEWORK_PATH=str(clean/'build/Build/Products/Debug'),TURTLEGIT_PREVIEW_CAPTURE_DIR=str(out),TURTLEGIT_CAPTURE_COMPARE_ONLY='1')
    result=run_receiver([str(receiver),'unused','/usr/bin/git'],cwd=root,env=env,capture_output=True,text=True,timeout=120)
    (out/'stdout.txt').write_text(result.stdout);(out/'stderr.txt').write_text(result.stderr)
    print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
    if 'Captured four real compact Commit/Comparison windows' not in result.stdout:raise RuntimeError('Native capture did not finish')
manifest={'method':'ScreenCaptureKit desktopIndependentWindow; actual native windows offscreen, original PNG bytes','repository':'Synthetic offline Harbor with branch merge, staged/unstaged files and draft; fixture commits only before capture baseline','preferences':'private suite removed; private HOME/CFFIXED_USER_HOME env','network':False,'owned_receiver_reaped':True,'assets':[]}
for name in ['commit-compact-light.png','commit-compact-dark.png','compare-compact-light-classic.png','compare-compact-dark-p4merge.png']:
    source=out/name;data=source.read_bytes();width,height=struct.unpack('>II',data[16:24])
    manifest['assets'].append(dict(raw_path=str(source.relative_to(root)),width=width,height=height,bytes=len(data),sha256=hashlib.sha256(data).hexdigest()))
manifest['clean_debug_root']=str(clean)
manifest['assets_not_published_pending_visual_acceptance']=True
manifest['stdout_sha256']=hashlib.sha256((out/'stdout.txt').read_bytes()).hexdigest();manifest['stderr_sha256']=hashlib.sha256((out/'stderr.txt').read_bytes()).hexdigest()
(root/'docs/qa/compact-selector-captures-2026-10-25.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps(manifest,indent=2))
