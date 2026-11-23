#!/usr/bin/env python3
"""Capture twelve current native primary appearances from an offline Harbor demo."""
import argparse
import datetime
import hashlib
import json
import os
import platform
import plistlib
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
from native_receiver import build_receiver, run_receiver

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--date', default='2026-11-23', type=datetime.date.fromisoformat,
                    help='Capture date; retain the historical default for existing callers.')
parser.add_argument('--debug-root',type=Path,help='Existing isolated source/build checkout; compile no application sources.')
scenes=('commit-classic','commit-staging','log','resolve','sync-history','sync-conflicts')
parser.add_argument('--only',action='append',choices=scenes,help='Capture only these scenes, both themes; retain unselected original assets and provenance.')
args=parser.parse_args()
selected=tuple(scene for scene in scenes if not args.only or scene in args.only)
stamp=args.date.isoformat()
root=Path(__file__).resolve().parent.parent
debug_root=(args.debug_root or root).resolve()
source=root/'docs/qa/manual-primary-captures-2026-11-23.swift'
out=root/('build/qa/manual-primary-captures-'+stamp)
out.mkdir(parents=True,exist_ok=True)
(out/'sources').mkdir(exist_ok=True)
prior_receipt=root/('docs/qa/manual-primary-captures-'+stamp+'.json')
previous=json.loads(prior_receipt.read_text()) if prior_receipt.exists() else {}
prior_attempt=None
if previous:
    # Preserve the entire original cohort, receipt and transformed fixture before
    # replacing any output, including when a focused repair later fails.
    prior_attempt=out/('prior-attempt-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
    prior_attempt.mkdir()
    shutil.copyfile(prior_receipt,prior_attempt/'receipt.json')
    for path in [*out.glob('*.png'),out/'stdout.txt',out/'stderr.txt']:
        if path.is_file():shutil.copyfile(path,prior_attempt/path.name)
    if (out/'sources').is_dir():shutil.copytree(out/'sources',prior_attempt/'sources')
receiver=build_receiver(debug_root,[source],out/'sources')
source_state=subprocess.check_output(['git','status','--porcelain=v1','--untracked-files=no'],cwd=debug_root,text=True)
object_paths=sorted((debug_root/'build/Build/Intermediates.noindex/TurtleGitMac.build/Debug/TurtleGitMac.build/Objects-normal'/platform.machine()).glob('*.o'))
object_digest=hashlib.sha256()
for object_path in object_paths:
    object_digest.update(str(object_path.relative_to(debug_root)).encode());object_digest.update(b'\0')
    with object_path.open('rb') as object_file:
        for chunk in iter(lambda:object_file.read(1024*1024),b''):object_digest.update(chunk)
app_object_receipt={'sha256':object_digest.hexdigest(),'architecture':platform.machine(),'object_count':len(object_paths),'algorithm':'SHA256 of sorted relative object paths, NUL separators and complete object bytes'}
with tempfile.TemporaryDirectory(prefix='turtlegit-primary-manual-') as private:
    context=Path(private)
    for name in ('home','tmp','xdg','repository'):(context/name).mkdir(mode=0o700)
    environment={k:v for k,v in os.environ.items() if not k.startswith('GIT_')}
    environment.update(HOME=str(context/'home'),CFFIXED_USER_HOME=str(context/'home'),
                       TMPDIR=str(context/'tmp')+'/',XDG_CONFIG_HOME=str(context/'xdg'),
                       GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',GIT_OPTIONAL_LOCKS='0',
                       DYLD_FRAMEWORK_PATH=str(debug_root/'build/Build/Products/Debug'),TURTLEGIT_PREVIEW_CAPTURE_DIR=str(out),TURTLEGIT_PREVIEW_CAPTURE_STAMP=stamp,TURTLEGIT_CAPTURE_SCENES=','.join(selected))
    try:
        result=run_receiver([str(receiver),str(context/'repository'),'/usr/bin/git'],cwd=debug_root,env=environment,
                            capture_output=True,text=True,timeout=150,timeout_sample=out/'timeout.sample.txt')
        (out/'stdout.txt').write_text(result.stdout);(out/'stderr.txt').write_text(result.stderr)
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if 'Captured current primary cohort; owned cleanup complete' not in result.stdout:
            raise RuntimeError('Capture did not complete actual window/worker cleanup')
        pids=[int(value) for value in re.findall(r'RECEIVER pid=(\d+)',result.stdout)]
        if len(pids)!=1:raise RuntimeError('Exact owned capture receiver PID missing')
        for pid in pids:
            try:os.kill(pid,0)
            except ProcessLookupError:pass
            else:raise RuntimeError(f'Owned capture receiver {pid} survived cleanup')
    except BaseException:
        evidence=Path(tempfile.mkdtemp(prefix='failed-',dir=out));shutil.copytree(context,evidence,dirs_exist_ok=True)
        print('Private failed capture evidence: '+str(evidence),flush=True);raise

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

bundle_metadata=[]
for info in sorted((debug_root/'build/Build/Products/Debug').glob('*.app/Contents/Info.plist')):
    details=plistlib.loads(info.read_bytes())
    bundle_metadata.append({'path':str(info.relative_to(debug_root)),
                            'sha256':sha(info),
                            'values':{key:value for key,value in details.items()
                                      if key in ('CFBundleIdentifier','CFBundleName','CFBundleShortVersionString','CFBundleVersion')
                                      or any(part in key.lower() for part in ('revision','commit','source'))}})

manifest={
    'source_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=debug_root,text=True).strip(),
    'validation_date':stamp,
    'scope':'Twelve primary screenshots assembled from explicitly recorded capture attempts; current attempt: '+', '.join(selected)+', each light/dark',
    'build':'Existing isolated unsigned Debug objects with matching recorded working-tree sources; independent of the installed user app. Newer Replay/Blame views are not pictured.',
    'debug_checkout':str(debug_root),
    'embedded_bundle_metadata':bundle_metadata,
    'source_state':{'base_head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=debug_root,text=True).strip(),'tracked_dirty':bool(source_state),'tracked_porcelain':source_state},
    'app_object_fingerprint':app_object_receipt,
    'app_link_fingerprint':receiver.parent.name,
    'provenance_note':'HEAD identifies the committed base, not dirty implementation changes. Production hashes, tracked status, object bytes and the native-receiver link fingerprint identify this attempt. Embedded bundle metadata is recorded separately and may predate those sources. This is an isolated linked receiver, not the installed app.',
    'scope_limit':'Only the selected primary windows are pictured; newer paused-Replay and Blame views are not pictured. Retained images preserve their earlier attempt provenance.',
    'status':'captured-visual-review-pending',
    'prior_capture_attempts':previous.get('attempts',previous.get('prior_capture_attempts',[])),
    'prior_attempt_receipt':str((prior_attempt/'receipt.json').relative_to(root)) if prior_attempt else None,
    'prior_attempt_receipt_sha256':sha(prior_attempt/'receipt.json') if prior_attempt else None,
    'current_attempt_scenes':list(selected),
    'prior_failed_fixture_sha256':previous.get('prior_failed_fixture_sha256',previous.get('fixture_sha256')),
    'prior_failed_runner_sha256':previous.get('prior_failed_runner_sha256',previous.get('runner_sha256')),
    'capture_presentation':'Deliberate brief visual acceptance using normal native window class/geometry. Exactly one owned window contained on screen; orderFront without activation or makeKey; compositor capture then immediately orderOut/close. No runtime overrides.',
    'method':'ScreenCaptureKit SCScreenshotManager desktopIndependentWindow for actual screen-contained alpha-one native window; original PNG bytes, no view.cacheDisplay or postprocessing',
    'repository':'Private offline Harbor demo plus separate paused merge; staged/unstaged/deleted/unversioned files, changelists and real local outgoing references; synthetic author, issue catalog/ID and draft',
    'native_presentation':'Production compact DialogTitles preference, actual Compact Commit layout dropdown and colored source icons; Per-dialog native content sizes; compositor retains actual native frame aspect ratio',
    'preserved':'HEAD, index tree, raw index/config and porcelain working status after setup; no Commit/stage/apply/save action during capture',
    'preferences':'Private suite removed; private CFFIXED_USER_HOME/TMPDIR/XDG and explicit global Git config; no user pasteboard or Keychain',
    'session_preflight':'CGSessionCopyCurrentDictionary refuses a locked desktop before demo Git repository/window creation; an unlocked desktop is required for ScreenCaptureKit.',
    'network':False,
    'desktop':'Deliberate visible visual capture, '+str(len(selected)*2)+' own windows one at a time; each screen-contained and sole visible receiver window, then immediately hidden/closed. No app activation, no user-owned app close/Quit/install',
    'owned_receiver_pids':pids,'owned_receiver_reaped_independently':True,
    'window_ids':[int(value) for value in re.findall(r'windowID=(\d+)',result.stdout)],
    'fixture_sha256':sha(source),'runner_sha256':sha(Path(__file__)),'receiver_sha256':sha(receiver),
    'stdout_sha256':sha(out/'stdout.txt'),'stderr_sha256':sha(out/'stderr.txt'),
    'production_sources_sha256':{str(p.relative_to(debug_root)):sha(p) for p in [debug_root/'Sources/TurtleGitMac/CommitWindow.swift',debug_root/'Sources/TurtleGitMac/CommitFileInteraction.swift',debug_root/'Sources/TurtleGitMac/PatchWindow.swift',debug_root/'Sources/TurtleGitMac/LogWindow.swift',debug_root/'Sources/TurtleGitMac/ResolveWindow.swift',debug_root/'Sources/TurtleGitMac/SynchronizationWindow.swift']},
    'review':'Pending human visual review; generated images alone do not establish visual parity or physical interaction',
    'assets':[]
}
if len(manifest['window_ids'])!=len(selected)*2:raise RuntimeError('Actual native capture count differs from selected cohort')
for kind in scenes:
    for theme in ('light','dark'):
        name=f'mac-{kind}-{theme}-{stamp}.png'
        if kind not in selected:
            prior=next((asset for asset in previous.get('assets',[]) if Path(asset['path']).name==name),None)
            if prior is None:raise RuntimeError('Focused capture requires an original asset receipt: '+name)
            target=root/prior['path']
            if sha(target)!=prior['sha256']:raise RuntimeError('Retained original asset hash changed: '+name)
            retained=dict(prior)
            retained.setdefault('capture_source_commit',previous['source_commit'])
            retained.setdefault('capture_app_sources_sha256',previous['production_sources_sha256'])
            retained.setdefault('capture_receiver_sha256',previous['receiver_sha256'])
            retained.setdefault('capture_source_state',previous.get('source_state',{'base_head':previous['source_commit'],'tracked_dirty':False,'basis':'Original isolated c8 checkout was source-verified clean before capture; explicit object fingerprint was not retained by that earlier runner.'}))
            retained.setdefault('capture_app_object_fingerprint',previous.get('app_object_fingerprint'))
            retained.setdefault('capture_link_fingerprint',previous.get('app_link_fingerprint'))
            retained['retained_from_prior_attempt']=manifest['prior_attempt_receipt']
            manifest['assets'].append(retained)
            continue
        raw=out/name;data=raw.read_bytes()
        if not data.startswith(b'\x89PNG\r\n\x1a\n'):raise RuntimeError('Invalid native PNG: '+name)
        width,height=struct.unpack('>II',data[16:24])
        if min(width,height)<400 or width<=height:raise RuntimeError('Unexpected native frame dimensions: '+name)
        target=root/'docs/site/assets'/name;shutil.copyfile(raw,target)
        manifest['assets'].append({'path':str(target.relative_to(root)),'raw_path':str(raw.relative_to(root)),
                                   'width':width,'height':height,'bytes':len(data),'sha256':sha(raw),
                                   'capture_source_commit':manifest['source_commit'],
                                   'capture_app_sources_sha256':manifest['production_sources_sha256'],
                                   'capture_receiver_sha256':manifest['receiver_sha256'],
                                   'capture_source_state':manifest['source_state'],
                                   'capture_app_object_fingerprint':manifest['app_object_fingerprint'],
                                   'capture_link_fingerprint':manifest['app_link_fingerprint'],
                                   'capture_link_generation':receiver.parent.name})
# Dimensions come from original compositor bytes, not expected window geometry.
homepage=root/'docs/site/index.html'
html=homepage.read_text()
for asset in manifest['assets']:
    image='assets/'+Path(asset['path']).name
    expression=r'(<img src="'+re.escape(image)+r'" width=")\d+(" height=")\d+(" )'
    html,count=re.subn(expression,lambda match:match[1]+str(asset['width'])+match[2]+str(asset['height'])+match[3],html)
    if count!=1:raise RuntimeError('Expected one homepage image for actual capture: '+image)
homepage.write_text(html)
prior_receipt.write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps(manifest,indent=2))
