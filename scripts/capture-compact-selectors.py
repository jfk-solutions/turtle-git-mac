#!/usr/bin/env python3
"""Capture real compact selectors or owned action errors using existing Debug objects."""
import argparse,hashlib,json,os,struct,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
root=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--only-errors',action='store_true',help='Three error-only captures; no Git fixture or Git actions')
parser.add_argument('--app-root',type=Path,default=Path('/Users/jkuehner/.codex/worktrees/finder-headless-registration/tortoise-git-mac'),help='Existing Debug app/object build root')
parser.add_argument('--output',type=Path)
parser.add_argument('--compare-only',action='store_true',help='Capture only the two Comparison windows without constructing Commit')
args=parser.parse_args();clean=args.app_root.resolve()
name='action-error-captures-2026-10-25' if args.only_errors else 'compact-selector-captures-2026-10-25'
out=(args.output or root/'build/qa'/name).absolute();out.mkdir(parents=True,exist_ok=True)
gen=out/'sources';gen.mkdir(exist_ok=True)
receiver=build_receiver(clean,[root/'docs/qa/compact-selector-captures-2026-10-25.swift'],gen)
with tempfile.TemporaryDirectory(prefix='turtlegit-owned-capture-') as private:
    context=Path(private).resolve()
    for folder in ['home','preferences','tmp','xdg']:(context/folder).mkdir(mode=0o700)
    env={k:v for k,v in os.environ.items() if not k.startswith('GIT_')}
    env.update(HOME=str(context/'home'),CFFIXED_USER_HOME=str(context/'preferences'),TMPDIR=str(context/'tmp')+'/',XDG_CONFIG_HOME=str(context/'xdg'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',DYLD_FRAMEWORK_PATH=str(clean/'build/Build/Products/Debug'),TURTLEGIT_PREVIEW_CAPTURE_DIR=str(out))
    if args.only_errors:env['TURTLEGIT_CAPTURE_ONLY_ERRORS']='1'
    if args.compare_only:env['TURTLEGIT_CAPTURE_COMPARE_ONLY']='1'
    result=run_receiver([str(receiver),'unused','/usr/bin/git'],cwd=root,env=env,capture_output=True,text=True,timeout=120)
    (out/'stdout.txt').write_text(result.stdout);(out/'stderr.txt').write_text(result.stderr)
    print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
    marker='Captured three real compact action error windows' if args.only_errors else 'Captured two real compact Comparison windows' if args.compare_only else 'Captured four real compact Commit/Comparison windows'
    if marker not in result.stdout:raise RuntimeError('Native capture did not finish')
manifest={'method':'ScreenCaptureKit desktopIndependentWindow; actual native windows offscreen, original PNG bytes','repository':'No repository or Git action in error-only mode' if args.only_errors else 'Synthetic offline Harbor with branch merge, staged/unstaged files and draft; fixture commits only before capture baseline','preferences':'Private HOME/CFFIXED_USER_HOME env; private suite for selector mode','network':False,'owned_receiver_reaped':True,'assets':[],'mode':'errors' if args.only_errors else 'selectors'}
names=['action-error-short-light.png','action-error-short-dark.png','action-error-long-light.png'] if args.only_errors else ['compare-compact-light-classic.png','compare-compact-dark-p4merge.png'] if args.compare_only else ['commit-compact-light.png','commit-compact-dark.png','compare-compact-light-classic.png','compare-compact-dark-p4merge.png']
for filename in names:
    source=out/filename;data=source.read_bytes();width,height=struct.unpack('>II',data[16:24])
    manifest['assets'].append(dict(raw_path=str(source),width=width,height=height,bytes=len(data),sha256=hashlib.sha256(data).hexdigest()))
manifest['debug_root']=str(clean);manifest['assets_not_published_pending_visual_acceptance']=True
manifest['stdout_sha256']=hashlib.sha256((out/'stdout.txt').read_bytes()).hexdigest();manifest['stderr_sha256']=hashlib.sha256((out/'stderr.txt').read_bytes()).hexdigest()
(out/'capture.json').write_text(json.dumps(manifest,indent=2)+'\n');print(json.dumps(manifest,indent=2))
