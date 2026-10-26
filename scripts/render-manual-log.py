#!/usr/bin/env python3
"""Render current native Log content without desktop screen capture.

Outputs remain private build artifacts until individually reviewed for the site.
These are AppKit content-view renders, not installed-app interaction evidence.
"""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile
from native_receiver import build_receiver, run_receiver

root = Path(__file__).resolve().parent.parent
output = root / 'build/qa/manual-log-renders-2026-10-26'
output.mkdir(parents=True, exist_ok=True)
generated = output / 'sources'
generated.mkdir(exist_ok=True)
fixture = root / 'docs/qa/manual-log-renders-2026-10-26.swift'
receiver = build_receiver(root, [fixture], generated)
trace = io.StringIO()
with tempfile.TemporaryDirectory(prefix='turtlegit-native-content-') as temporary:
    private = Path(temporary).resolve()
    for name in ['home', 'preferences', 'tmp', 'xdg', 'fixture']:
        (private / name).mkdir(mode=0o700)
    environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    environment.update(HOME=str(private / 'home'), CFFIXED_USER_HOME=str(private / 'preferences'),
                       TMPDIR=str(private / 'tmp') + '/', XDG_CONFIG_HOME=str(private / 'xdg'),
                       GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                       DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'),
                       TURTLEGIT_PREVIEW_CAPTURE_DIR=str(output))
    with contextlib.redirect_stdout(trace):
        result = run_receiver([str(receiver), str(private / 'fixture'), '/usr/bin/git'],
                              cwd=root, env=environment, capture_output=True, text=True,
                              timeout=120, timeout_sample=output / 'timeout.sample.txt')
    (output / 'receiver-trace.txt').write_text(trace.getvalue())
    (output / 'stdout.txt').write_text(result.stdout)
    (output / 'stderr.txt').write_text(result.stderr)
    print(trace.getvalue(), end='')
    print(result.stdout, end='')
    print(result.stderr, end='')
    result.check_returncode()
    if 'Rendered two current native Log content views in light/dark.' not in result.stdout:
        raise RuntimeError('Native rendering did not reach integrity and cleanup completion')
pids = list(map(int, re.findall(r'Owned receiver reaped: (\d+)', trace.getvalue())))
if len(pids) != 1:
    raise RuntimeError('Owned render receiver identity missing')
for pid in pids:
    probe = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'pid='], capture_output=True, text=True)
    if probe.returncode != 1 or probe.stdout.strip():
        raise RuntimeError('Owned render receiver remains alive')
assets = []
for kind in ['log']:
    for appearance in ['light', 'dark']:
        file = output / f'mac-{kind}-{appearance}-2026-10-26.png'
        data = file.read_bytes()
        if data[:8] != b'\x89PNG\r\n\x1a\n':
            raise RuntimeError('Invalid native PNG')
        width, height = struct.unpack('>II', data[16:24])
        assets.append(dict(raw_path=str(file.relative_to(root)), width=width, height=height,
                           bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
manifest = dict(method='CALayer render into private bitmap; actual native content views, no OS window chrome',
                desktop_screen_capture=False, installed_UI_acceptance=False,
                git_head=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
                receiver=str(receiver.relative_to(root)), receiver_pids=pids,
                receiver_reaped_and_independently_absent=True,
                fixture_sha256=hashlib.sha256(fixture.read_bytes()).hexdigest(),
                preferences='Private suite, HOME/CFFIXED_USER_HOME; no user preferences',
                repository='Private synthetic Harbor; HEAD/index tree/status unchanged after construction',
                network=False, assets=assets, publication='Pending individual visual review')
(output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print('PASS: two native Log content renders; private data preserved; owned receiver absent')
