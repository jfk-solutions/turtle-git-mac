#!/usr/bin/env python3
"""Capture four current native Commit appearances from an offline Harbor demo."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
from native_receiver import build_receiver, run_receiver

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--date', default='2026-10-29', type=datetime.date.fromisoformat,
                    help='Capture date; retain the historical default for existing callers.')
args=parser.parse_args()
stamp=args.date.isoformat()
root=Path(__file__).resolve().parent.parent
source=root/'docs/qa/manual-commit-captures-2026-10-29.swift'
out=root/('build/qa/manual-commit-captures-'+stamp)
out.mkdir(parents=True,exist_ok=True)
(out/'sources').mkdir(exist_ok=True)
prior_receipt=root/('docs/qa/manual-commit-captures-'+stamp+'.json')
previous=json.loads(prior_receipt.read_text()) if prior_receipt.exists() else {}
receiver=build_receiver(root,[source],out/'sources')
with tempfile.TemporaryDirectory(prefix='turtlegit-commit-manual-') as private:
    context=Path(private).resolve()
    for name in ('home','tmp','xdg','repository'):(context/name).mkdir(mode=0o700)
    environment={k:v for k,v in os.environ.items() if not k.startswith('GIT_')}
    environment.update(CFFIXED_USER_HOME=str(context/'home'),
                       TMPDIR=str(context/'tmp')+'/',XDG_CONFIG_HOME=str(context/'xdg'),
                       GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',GIT_OPTIONAL_LOCKS='0',
                       DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),TURTLEGIT_PREVIEW_CAPTURE_DIR=str(out),TURTLEGIT_PREVIEW_CAPTURE_STAMP=stamp)
    try:
        result=run_receiver([str(receiver),str(context/'repository'),'/usr/bin/git'],cwd=root,env=environment,
                            capture_output=True,text=True,timeout=150,timeout_sample=out/'timeout.sample.txt')
        (out/'stdout.txt').write_text(result.stdout);(out/'stderr.txt').write_text(result.stderr)
        print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
        if 'Captured four real current Commit windows; owned cleanup complete' not in result.stdout:
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

manifest={
    'source_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
    'validation_date':stamp,
    'scope':'Four current Commit screenshots: Classic and GitGui staging, each light/dark',
    'build':'Current unsigned Debug objects; independent of the installed user app and signed consolidation',
    'status':'captured-visual-review-pending',
    'prior_capture_attempts':previous.get('attempts',previous.get('prior_capture_attempts',[])),
    'prior_failed_fixture_sha256':previous.get('prior_failed_fixture_sha256',previous.get('fixture_sha256')),
    'prior_failed_runner_sha256':previous.get('prior_failed_runner_sha256',previous.get('runner_sha256')),
    'capture_presentation':'Deliberate brief visual acceptance using normal native window class/geometry. Exactly one owned window contained on screen; orderFront without activation or makeKey; compositor capture then immediately orderOut/close. No runtime overrides.',
    'method':'ScreenCaptureKit SCScreenshotManager desktopIndependentWindow for actual screen-contained alpha-one native window; original PNG bytes, no view.cacheDisplay or postprocessing',
    'repository':'Private offline Harbor demo with staged/unstaged/deleted/unversioned files and changelists; synthetic author, issue catalog/ID and draft',
    'native_presentation':'Production compact DialogTitles preference, actual Compact Commit layout dropdown and colored source icons; 1160x840 content points, compositor retains actual native frame aspect ratio',
    'preserved':'HEAD, index tree, raw index/config and porcelain working status after setup; no Commit/stage/apply/save action during capture',
    'preferences':'Private suite removed; private CFFIXED_USER_HOME/TMPDIR/XDG and explicit global Git config; no user pasteboard or Keychain',
    'session_preflight':'CGSessionCopyCurrentDictionary refuses a locked desktop before demo Git repository/window creation; an unlocked desktop is required for ScreenCaptureKit.',
    'network':False,
    'desktop':'Deliberate visible visual capture, four own windows one at a time; each screen-contained and sole visible receiver window, then immediately hidden/closed. No app activation, no user-owned app close/Quit/install',
    'owned_receiver_pids':pids,'owned_receiver_reaped_independently':True,
    'window_ids':[int(value) for value in re.findall(r'windowID=(\d+)',result.stdout)],
    'fixture_sha256':sha(source),'runner_sha256':sha(Path(__file__)),'receiver_sha256':sha(receiver),
    'stdout_sha256':sha(out/'stdout.txt'),'stderr_sha256':sha(out/'stderr.txt'),
    'production_sources_sha256':{str(p.relative_to(root)):sha(p) for p in [root/'Sources/TurtleGitMac/CommitWindow.swift',root/'Sources/TurtleGitMac/CommitFileInteraction.swift',root/'Sources/TurtleGitMac/PatchWindow.swift']},
    'review':'Pending human visual review; generated images alone do not establish visual parity or physical interaction',
    'assets':[]
}
if len(manifest['window_ids'])!=4:raise RuntimeError('Expected exactly four actual native captures')
for kind in ('commit-classic','commit-staging'):
    for theme in ('light','dark'):
        name=f'mac-{kind}-{theme}-{stamp}.png';raw=out/name;data=raw.read_bytes()
        if not data.startswith(b'\x89PNG\r\n\x1a\n'):raise RuntimeError('Invalid native PNG: '+name)
        width,height=struct.unpack('>II',data[16:24])
        if min(width,height)<400 or width<=height:raise RuntimeError('Unexpected native frame dimensions: '+name)
        target=root/'docs/site/assets'/name;shutil.copyfile(raw,target)
        manifest['assets'].append({'path':str(target.relative_to(root)),'raw_path':str(raw.relative_to(root)),
                                   'width':width,'height':height,'bytes':len(data),'sha256':sha(raw)})
prior_receipt.write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps(manifest,indent=2))
