#!/usr/bin/env python3
"""Capture eight current Debug native dialog appearances for the manual, offline."""
import argparse
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
parser.add_argument('--only-unified-diff', action='store_true')
args=parser.parse_args()
root = Path(__file__).resolve().parent.parent
source = root/'docs/qa/manual-current-captures-2026-10-27.swift'
out = root/'build/qa/manual-current-captures-2026-10-27'
out.mkdir(parents=True, exist_ok=True)
(out/'sources').mkdir(exist_ok=True)
receiver = build_receiver(root, [source], out/'sources')
with tempfile.TemporaryDirectory(prefix='turtlegit-manual-current-') as private:
    context = Path(private).resolve()
    for name in ('home', 'tmp', 'xdg', 'repository'):
        (context/name).mkdir(mode=0o700)
    environment = {k:v for k,v in os.environ.items() if not k.startswith('GIT_')}
    environment.update(HOME=str(context/'home'), CFFIXED_USER_HOME=str(context/'home'),
                       TMPDIR=str(context/'tmp')+'/', XDG_CONFIG_HOME=str(context/'xdg'),
                       GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0', GIT_OPTIONAL_LOCKS='0',
                       DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), TURTLEGIT_PREVIEW_CAPTURE_DIR=str(out))
    try:
        result = run_receiver([str(receiver), str(context/'repository'), '/usr/bin/git']+(['unified-diff-only'] if args.only_unified_diff else []), cwd=root,
                              env=environment, capture_output=True, text=True, timeout=150,
                              timeout_sample=out/'timeout.sample.txt')
        (out/'stdout.txt').write_text(result.stdout)
        (out/'stderr.txt').write_text(result.stderr)
        print(result.stdout, end=''); print(result.stderr, end='')
        result.check_returncode()
        if 'real current native windows; owned cleanup complete' not in result.stdout:
            raise RuntimeError('Native capture ended without its cleanup sentinel')
        pids = [int(value) for value in re.findall(r'RECEIVER pid=(\d+)', result.stdout)]
        if len(pids) != 1:
            raise RuntimeError('Missing exact owned receiver PID')
        for pid in pids:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                pass
            else:
                raise RuntimeError(f'Owned receiver {pid} survived native cleanup')
    except BaseException:
        evidence = Path(tempfile.mkdtemp(prefix='failed-', dir=out))
        shutil.copytree(context, evidence, dirs_exist_ok=True)
        print('Private failed capture evidence: '+str(evidence), flush=True)
        raise

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

manifest = {
    'source_commit': subprocess.check_output(['git','rev-parse','HEAD'], cwd=root, text=True).strip(),
    'build': 'Existing current unsigned Debug application objects; not the installed signed shipping app',
    'method': 'ScreenCaptureKit SCScreenshotManager desktopIndependentWindow, actual native windows offscreen; untouched original PNG bytes',
    'repository': 'Private synthetic offline Harbor repository with real merge graph, staged/unstaged files and draft; fixture commits before capture baseline only',
    'preserved': 'HEAD, index tree, raw index/config bytes and porcelain working status; no Commit/stage/apply/save mutations during capture',
    'preferences': 'Private suite removed; private HOME/CFFIXED_USER_HOME/TMPDIR/XDG; no user pasteboard use',
    'network': False,
    'owned_receiver_pids': pids,
    'owned_receiver_reaped_independently': True,
    'owned_windows': 'Eight final distinct native window assets. Original run captured eight; focused landscape repair captured only two standalone editable Unified Diff documents. Every owner closed after its capture, all workers drained.',
    'current_attempt_window_ids': [int(value) for value in re.findall(r'windowID=(\d+)', result.stdout)],
    'current_attempt_scope': 'Unified Diff light/dark only' if args.only_unified_diff else 'All eight native appearances',
    'unified_diff_mode': 'Standalone editable PatchWindowController document; actual native gutter and rectangular selection; no staging/apply mutation',
    'fixture_sha256': sha(source), 'runner_sha256': sha(Path(__file__)),
    'receiver_sha256': sha(receiver), 'stdout_sha256': sha(out/'stdout.txt'), 'stderr_sha256': sha(out/'stderr.txt'),
    'assets': []
}
prior = out/'first-portrait-attempt'/'manual-current-captures-2026-10-27.json'
if args.only_unified_diff:
    previous=json.loads(prior.read_text())
    manifest['prior_attempt']={'manifest':str(prior.relative_to(root)), 'sha256':sha(prior), 'owned_receiver_pids':previous['owned_receiver_pids'], 'scope':'Initial eight actual native windows, including portrait Unified Diff; six approved Log/Commit assets retained byte-exact'}
    manifest['all_owned_receiver_pids']=previous['owned_receiver_pids']+pids
for kind in ('log','commit-classic','commit-staging','unified-diff'):
    for theme in ('light','dark'):
        name = f'mac-{kind}-{theme}-2026-10-27.png'
        raw = out/name
        data = raw.read_bytes()
        width,height = struct.unpack('>II', data[16:24])
        if not data.startswith(b'\x89PNG\r\n\x1a\n') or min(width,height)<400:
            raise RuntimeError('Invalid or unexpectedly small actual native PNG: '+name)
        target = root/'docs/site/assets'/name
        shutil.copyfile(raw, target)
        manifest['assets'].append(dict(path=str(target.relative_to(root)), raw_path=str(raw.relative_to(root)),
                                       width=width,height=height,bytes=len(data),sha256=sha(raw),
                                       capture_attempt='landscape-repair' if args.only_unified_diff and kind=='unified-diff' else 'initial-eight'))
(root/'docs/qa/manual-current-captures-2026-10-27.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps(manifest,indent=2))
