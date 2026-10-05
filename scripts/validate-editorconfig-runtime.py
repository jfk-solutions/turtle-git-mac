#!/usr/bin/env python3
"""Audit the packaged parser, provenance, source archives and runtime behavior."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('runtime', type=pathlib.Path)
args = parser.parse_args()
runtime = args.runtime
pin = json.loads((ROOT / 'Configuration/EditorConfigRuntime.json').read_text())
manifest = json.loads((runtime / 'provenance.json').read_text())
assert manifest['pins'] == pin, 'EditorConfig source pin mismatch'
binary = runtime / 'editorconfig'
assert hashlib.sha256(binary.read_bytes()).hexdigest() == manifest['binary_sha256'], 'EditorConfig binary checksum mismatch'
archs = set(subprocess.check_output(['lipo', '-archs', binary], text=True).split())
assert archs == set(pin['architectures'])
versions = subprocess.check_output(['xcrun', 'vtool', '-show-build', binary], text=True)
assert re.findall(r'\bminos\s+([0-9.]+)', versions) == [pin['deployment_target']] * len(archs)
for line in subprocess.check_output(['otool', '-L', binary], text=True).splitlines():
    if line.startswith('\t'):
        assert line.strip().split(' (')[0].startswith(('/usr/lib/', '/System/Library/')), line
for name in ['editorconfig', 'pcre2', 'core_tests']:
    assert hashlib.sha256((runtime / 'Sources' / (name + '.tar.gz')).read_bytes()).hexdigest() == pin[name]['sha256']
for name in ['EditorConfig-LICENSE.txt', 'PCRE2-LICENSE.txt']:
    assert (runtime / 'Licenses' / name).stat().st_size > 100
assert (runtime / 'Sources/build/scripts/build-editorconfig-runtime.py').is_file()
assert json.loads((runtime / 'Sources/build/Configuration/EditorConfigRuntime.json').read_text()) == pin
if manifest.get('signed'):
    subprocess.run(['codesign', '--verify', '--strict', binary], check=True)
    if manifest.get('sandbox_inherited'):
        output = subprocess.check_output(['codesign', '-d', '--entitlements', ':-', binary], stderr=subprocess.STDOUT)
        start = output.index(b'<?xml')
        end = output.index(b'</plist>', start) + len(b'</plist>')
        entitlements = plistlib.loads(output[start:end])
        assert entitlements == {'com.apple.security.app-sandbox': True, 'com.apple.security.inherit': True}
        # An inherited sandbox helper cannot run from this unsandboxed Python
        # parent. The identical unsigned binary was exercised before signing;
        # signed app invocation and security scopes need native acceptance.
        print('EditorConfig: signed inherited-sandbox helper, provenance, architectures and resources verified; native sandbox invocation requires app acceptance.')
        raise SystemExit(0)
with tempfile.TemporaryDirectory(prefix='TurtleGitEditorConfigAudit-') as folder:
    root = pathlib.Path(folder)
    (root / 'child').mkdir()
    (root / '.editorconfig').write_text('root=true\n[*.{txt,md}]\nindent_style=space\nindent_size=3\ntab_width=5\n[part{1..3}.txt]\ntab_width=7\n')
    (root / 'child/.editorconfig').write_text('[part2.txt]\nindent_size=unset\ntab_width=6\n')
    for name, width in [('part1.txt', '7'), ('part2.txt', '6'), ('readme.md', '5')]:
        output = subprocess.check_output([binary, str(root / 'child' / name)], text=True)
        values = dict(line.split('=', 1) for line in output.splitlines())
        assert values['tab_width'] == width and values['indent_style'] == 'space'
        if name == 'part2.txt':
            assert values['indent_size'] == 'unset'
print('EditorConfig: universal macOS 13 parser, system linkage, licenses, source pins and inherited rules verified.')
