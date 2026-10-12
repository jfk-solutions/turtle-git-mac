#!/usr/bin/env python3
"""Audit merge adapter provenance and per-slice linkage/deployment, without launching it."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import re
import subprocess

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('runtime', type=Path)
args = parser.parse_args(); runtime = args.runtime.resolve()
manifest = json.loads((runtime / 'provenance.json').read_text()); binary = runtime / 'merge-diff'
assert manifest['subversion'] == json.loads((root / 'Configuration/GitSVNRuntime.json').read_text())['sources']['subversion']
source = 'Sources/TurtleGitMergeDiff/main.c'
assert (runtime / 'Sources/build' / source).read_bytes() == (root / source).read_bytes()
assert hashlib.sha256((root / source).read_bytes()).hexdigest() == manifest['source_sha256']
assert hashlib.sha256(binary.read_bytes()).hexdigest() == manifest['binary_sha256']
assert (runtime / 'LICENSE').read_bytes() == (root / 'LICENSE').read_bytes()
for name in ['build-merge-diff-runtime.py', 'validate-merge-diff-runtime.py']:
    assert (runtime / 'Sources/build/scripts' / name).read_bytes() == (root / 'scripts' / name).read_bytes()
assert set(subprocess.check_output(['lipo', '-archs', binary], text=True).split()) == set(manifest['architectures']) == {'arm64', 'x86_64'}
versions = subprocess.check_output(['xcrun', 'vtool', '-show-build', binary], text=True)
assert re.findall(r'\bminos\s+([0-9.]+)', versions) == ['13.0', '13.0']
for line in subprocess.check_output(['otool', '-L', binary], text=True).splitlines():
    if line.startswith('\t'): assert line.strip().split(' (')[0].startswith(('/usr/lib/', '/System/Library/')), line
if manifest.get('signed'):
    subprocess.run(['codesign', '--verify', '--strict', str(binary)], check=True)
    if manifest.get('sandbox_inherited'):
        content = subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(binary)], stderr=subprocess.STDOUT)
        start = content.index(b'<?xml'); end = content.index(b'</plist>', start) + len(b'</plist>')
        assert plistlib.loads(content[start:end]) == {'com.apple.security.app-sandbox': True, 'com.apple.security.inherit': True}
print('MergeDiff: universal macOS 13 adapter, source provenance and system-only direct linkage verified; dynamic GitSVN libraries require the separate runtime audit.')
