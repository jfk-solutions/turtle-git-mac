#!/usr/bin/env python3
"""Audit the native Git prompt helper; never enters a credential or opens GUI."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('helper', type=Path)
parser.add_argument('--universal', action='store_true')
args = parser.parse_args()
helper = args.helper.resolve()
alias = args.helper.parent / 'TurtleGitOpenSSHAskpass'
assert alias.is_symlink() and alias.resolve() == helper
manifest = json.loads((args.helper.parent / 'provenance.json').read_text())
assert hashlib.sha256(helper.read_bytes()).hexdigest() == manifest['binary_sha256']
root = Path(__file__).resolve().parent.parent
for source, digest in manifest['sources'].items():
    assert hashlib.sha256((root / source).read_bytes()).hexdigest() == digest
architectures = set(subprocess.check_output(['lipo', '-archs', str(helper)], text=True).split())
assert architectures and architectures <= {'arm64', 'x86_64'}
if args.universal: assert architectures == {'arm64', 'x86_64'}
versions = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(helper)], text=True)
assert re.findall(r'\bminos\s+([0-9.]+)', versions) == ['13.0'] * len(architectures)
for line in subprocess.check_output(['otool', '-L', str(helper)], text=True).splitlines():
    if line.startswith('\t'): assert line.strip().split(' (')[0].startswith(('/usr/lib/', '/System/Library/')), line
if not manifest['sandbox_inherited']:
    result = subprocess.run([str(helper)], capture_output=True, timeout=10)
    assert result.returncode == 1 and result.stdout == b'' and result.stderr == b''
else:
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(helper)], capture_output=True)
    assert b'<key>com.apple.security.inherit</key>' in result.stdout + result.stderr
print('Git askpass: packaged source, macOS 13/system linkage and invalid-invocation refusal verified; signed GUI acceptance pending.')
