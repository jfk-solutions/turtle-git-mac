#!/usr/bin/env python3
"""Audit the packaged response helper. No real credentials or GUI are used."""
import argparse
import os
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
parser = argparse.ArgumentParser()
parser.add_argument('helper', type=Path)
parser.add_argument('--universal', action='store_true')
args = parser.parse_args()
helper = args.helper.resolve()
assert helper.is_file() and os.access(helper, os.X_OK)
root_source = Path(__file__).resolve().parent.parent
manifest = json.loads((helper.parent/'provenance.json').read_text())
assert manifest['binary_sha256'] == hashlib.sha256(helper.read_bytes()).hexdigest()
assert manifest['source_sha256'] == hashlib.sha256((root_source/'Sources/TurtleGitSSHAskpass/main.swift').read_bytes()).hexdigest()
architectures = set(subprocess.check_output(['/usr/bin/lipo','-archs',str(helper)],text=True).split())
assert architectures <= {'arm64','x86_64'} and architectures
if args.universal:
    assert architectures == {'arm64','x86_64'}
versions = subprocess.check_output(['xcrun','vtool','-show-build',str(helper)],text=True)
assert re.findall(r'\bminos\s+([0-9.]+)',versions) == ['13.0'] * len(architectures)
for line in subprocess.check_output(['/usr/bin/otool','-L',str(helper)],text=True).splitlines():
    if line.startswith('\t'):
        assert line.strip().split(' (')[0].startswith(('/usr/lib/','/System/Library/')), line
# Inherited-sandbox helpers require invocation by the signed app. Do not pretend
# an unsigned Python parent supplies that sandbox.
signature = subprocess.run(['/usr/bin/codesign','-d','--entitlements',':-',str(helper)],capture_output=True)
entitlements = signature.stdout + signature.stderr
if manifest.get('sandbox_inherited'):
    assert b'<key>com.apple.security.inherit</key>' in entitlements
    subprocess.run(['/usr/bin/codesign','--verify','--strict',str(helper)],check=True)
    print('SSH askpass architectures/linkage checked; signed inherited invocation needs native app acceptance.')
    raise SystemExit(0)
with tempfile.TemporaryDirectory(prefix='turtlegit-askpass-audit-') as folder:
    root = Path(folder); directory = root/'tg-agent-fixture'; directory.mkdir(mode=0o700)
    file = directory/'credential-fixture'
    response = b'private fixture response'
    file.write_bytes(b'TurtleGitSSHAskpass\0'+response); file.chmod(0o600)
    environment = os.environ.copy(); environment['TURTLEGIT_SSH_CREDENTIAL_FILE'] = str(file)
    result = subprocess.run([str(helper)],env=environment,capture_output=True)
    assert result.returncode == 0 and result.stdout == response+b'\n' and result.stderr == b''
    assert not file.exists()
    replay = subprocess.run([str(helper)],env=environment,capture_output=True)
    assert replay.returncode != 0 and not replay.stdout and not replay.stderr
print('SSH askpass: macOS 13/system linkage, private one-use fixture response and replay refusal verified; signing acceptance pending.')
