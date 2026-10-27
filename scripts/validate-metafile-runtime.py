#!/usr/bin/env python3
"""Verify universal slices, system-only linkage and corresponding metafile sources."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import struct
import subprocess
import tempfile
import xml.etree.ElementTree as ET
ROOT = pathlib.Path(__file__).resolve().parents[1]
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def wmf_rectangle():
    def record(function, *words): return struct.pack('<IH', 3 + len(words), function) + struct.pack('<' + 'H' * len(words), *words)
    records = record(0x020B, 0, 0) + record(0x020C, 100, 100) + record(0x041B, 90, 90, 10, 10) + record(0)
    return struct.pack('<HHHIHIH', 1, 9, 0x300, 9 + len(records)//2, 0, 7, 0) + records

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('runtime', type=pathlib.Path)
    parser.add_argument('--structure-only', action='store_true', help='Skip executing the helper (used while signing/embedding)')
    parser.add_argument('--all-architectures', action='store_true')
    args = parser.parse_args()
    runtime = args.runtime.resolve()
    manifest = json.loads((runtime / 'provenance.json').read_text())
    pin = json.loads((ROOT / 'Configuration/MetafileRuntime.json').read_text())
    assert manifest['pin'] == pin
    assert digest(runtime / 'LICENSE-Wine-hatches') == pin['hatch_patterns']['license_sha256']
    assert digest(ROOT / pin['hatch_patterns']['license_file']) == pin['hatch_patterns']['license_sha256']
    assert digest(runtime / 'LICENSE-BaseHmiTypes') == pin['classic_clipping']['license_sha256']
    assert digest(ROOT / pin['classic_clipping']['license_file']) == pin['classic_clipping']['license_sha256']
    binary = runtime / 'metafile-convert'
    assert digest(binary) == manifest['binary_sha256']
    assert digest(runtime / 'renderer.js') == manifest['renderer_sha256']
    curve_data = (runtime / 'color-curves.bin').read_bytes()
    assert len(curve_data) == 598032 and curve_data[:16] == b'TGCCLUT1' + struct.pack('<II', 2336, 256)
    assert hashlib.sha256(curve_data).hexdigest() == pin['image_effects']['curve_lookup']['sha256']
    assert set(manifest['resource_sha256']) == {'color-curves.bin', 'color-curves.json'}
    for relative, expected in manifest['resource_sha256'].items():
        assert digest(runtime / relative) == expected, relative
        assert manifest['source_sha256']['Sources/TurtleGitMetafile/Resources/' + relative] == expected, relative
    curve_metadata = json.loads((runtime / 'color-curves.json').read_text())
    assert curve_metadata['sha256'] == hashlib.sha256(curve_data).hexdigest()
    assert curve_metadata['table_count'] == 2336 and curve_metadata['table_bytes'] == 256
    for relative, expected in manifest['source_sha256'].items():
        assert digest(ROOT / relative) == expected, relative
        assert digest(runtime / 'Sources/build' / relative) == expected, relative
    for relative, expected in manifest['license_sha256'].items(): assert digest(runtime / relative) == expected, relative
    assert digest(runtime / 'Sources/renderer.tar.gz') == pin['renderer']['sha256']
    # Regenerate the JS independently from the checked archive and exact local patch.
    from importlib.util import spec_from_file_location, module_from_spec
    spec = spec_from_file_location('metafile_builder', ROOT / 'scripts/build-metafile-runtime.py')
    builder = module_from_spec(spec); spec.loader.exec_module(builder)
    with tempfile.TemporaryDirectory(prefix='metafile-verify-') as directory:
        source = pathlib.Path(directory)
        builder.extract(runtime / 'Sources/renderer.tar.gz', source)
        subprocess.run(['/usr/bin/patch', '-f', '-F', '0', '-p1', '-i', str(runtime / 'Sources/build/patches/metafile-renderer.patch')], cwd=source, check=True, capture_output=True)
        assert builder.bundle(source).encode() == (runtime / 'renderer.js').read_bytes(), 'Renderer does not match corresponding source'
    archs = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()
    assert set(archs) == set(pin['architectures'])
    for arch in archs:
        versions = subprocess.check_output(['xcrun', 'vtool', '-arch', arch, '-show-build', str(binary)], text=True)
        assert re.findall(r'\bminos\s+([0-9.]+)', versions) == [pin['deployment_target']]
        links = subprocess.check_output(['otool', '-arch', arch, '-L', str(binary)], text=True)
        for line in links.splitlines()[1:]: assert line.strip().split(' ', 1)[0].startswith(('/usr/lib/', '/System/Library/')), line
    if manifest.get('signed'):
        subprocess.run(['codesign', '--verify', '--strict', str(binary)], check=True)
        assert re.fullmatch('[0-9a-f]{64}', manifest['unsigned_binary_sha256'])
        if manifest.get('sandbox_inherited'):
            display = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(binary)], capture_output=True, check=True)
            entitlements = plistlib.loads(display.stdout)
            assert entitlements.get('com.apple.security.app-sandbox') and entitlements.get('com.apple.security.inherit')
            print('Metafile: source, license, universal slices and inherited signature verified; signed parent invocation remains separate.')
            return
    else: assert not manifest.get('sandbox_inherited')
    if not args.structure_only:
        prefixes = [['arch', '-' + arch] for arch in pin['architectures']] if args.all_architectures else [[]]
        for prefix in prefixes:
            for flags, raw in [(['--wmf'], b''), (['--emf'], b'bad'), (['--bad'], b'bad'), (['--wmf'], b'bad')]:
                result = subprocess.run(prefix + [str(binary), *flags], input=raw, capture_output=True, timeout=15)
                assert result.returncode != 0 and result.stderr and not result.stdout
            result = subprocess.run(prefix + [str(binary), '--wmf'], input=wmf_rectangle(), capture_output=True, timeout=15)
            assert result.returncode == 0, result.stderr.decode(errors='replace')
            svg = ET.fromstring(result.stdout)
            assert svg.tag == '{http://www.w3.org/2000/svg}svg'
            assert any(node.tag.rsplit('}', 1)[-1] in {'path', 'rect', 'polygon'} for node in svg.iter()), 'WMF produced an empty SVG'
    print('Metafile: pinned MIT renderer/LGPL hatch source, reconstruction, universal macOS13 helper and SDK-only dependencies verified' + (' (structure only).' if args.structure_only else ' with actual conversion/rejection.'))
if __name__ == '__main__': main()
