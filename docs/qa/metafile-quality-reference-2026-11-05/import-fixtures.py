#!/usr/bin/env python3
"""Import independently captured Windows bytes without invoking TurtleGit."""
import argparse
import hashlib
import json
from pathlib import Path, PureWindowsPath
import struct
import zlib

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('capture', type=Path)
args = parser.parse_args()
capture = args.capture.resolve()
report = json.loads((capture / 'quality-observations.json').read_text(encoding='utf-8-sig'))
assert report['requestedCaseCount'] == report['completedCaseCount'] == len(report['cases']) == 53
assert (report['width'], report['height']) == (128, 96)
assert (capture / 'source-revision.txt').read_text(encoding='utf-8-sig').strip() == 'd39b4ff42a0e5f9161ca6b4f40d0436c7400c19c'

def sha(data):
    return hashlib.sha256(data).hexdigest()

identities = json.loads((capture / 'sha256.json').read_text(encoding='utf-8-sig'))
expected = {PureWindowsPath(entry['Path']).name: entry['Hash'].lower() for entry in identities}
verified = 0
for path in capture.iterdir():
    if path.is_file() and path.name in expected:
        assert sha(path.read_bytes()) == expected[path.name], path.name
        verified += 1
source_identities = {}
for path in [Path(__file__).parent / 'QualityReference.cpp', Path(__file__).parent / 'README.md',
             ROOT / '.github/workflows/metafile-quality-reference.yml']:
    content = path.read_bytes()
    # actions/checkout on the measured Windows runner checks text out as CRLF.
    # Accept only the identical source bytes with that explicit line-ending
    # conversion; retain both identities instead of discarding the difference.
    windows = content.replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')
    assert expected[path.name] in [sha(content), sha(windows)], path.name
    source_identities[path.name] = {'repository_sha256': sha(content), 'windows_checkout_sha256': expected[path.name]}

def png(rgba, width, height):
    def chunk(kind, content):
        return struct.pack('>I', len(content)) + kind + content + struct.pack('>I', zlib.crc32(kind + content) & 0xffffffff)
    rows = b''.join(b'\0' + rgba[y * width * 4:(y + 1) * width * 4] for y in range(height))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(rows, 9)) + chunk(b'IEND', b''))

destination = ROOT / 'Tests/TurtleGitCoreTests/Fixtures/Metafile/Quality'
destination.mkdir(parents=True, exist_ok=True)
manifest = {
    'schema': 1,
    'source_run': 41938727574,
    'source_commit': 'd39b4ff42a0e5f9161ca6b4f40d0436c7400c19c',
    'artifact_id': 13374649845,
    'artifact_zip_sha256': 'bca1e883888e790f92174fdf0803b3b3202b3435b79c902cf5091acff7f5cfee',
    'verified_capture_hashes': verified,
    'source_identities': source_identities,
    'width': 128, 'height': 96,
    'expected_pixels': 'Natural Windows GDI+ playback; PNG losslessly encodes complete top-down straight RGBA including transparent pixels. No TurtleGit output is used.',
    'limits': 'Captured ordinary fills and source state, not certification of every Windows stroke endpoint, native curve metric or arbitrary metafile.',
    'cases': [],
}
for case in report['cases']:
    name = case['name']
    assert '/' not in name and '\\' not in name
    wire = (capture / (name + '.emf')).read_bytes()
    rgba = (capture / (name + '-natural.rgba')).read_bytes()
    assert len(rgba) == 128 * 96 * 4
    assert case['directNaturalPixelMismatches'] == 0
    assert case['reserved']['originalNaturalPixelMismatches'] == 0
    encoded = png(rgba, 128, 96)
    (destination / (name + '.emf')).write_bytes(wire)
    (destination / (name + '.windows.png')).write_bytes(encoded)
    manifest['cases'].append({
        'name': name, 'requested': case['requested'], 'states': case['directStates'],
        'wire_sha256': sha(wire), 'windows_rgba_sha256': sha(rgba), 'windows_png_sha256': sha(encoded),
        'picture_rgba_sha256': sha((capture / (name + '-picture.rgba')).read_bytes()),
        'direct_rgba_sha256': sha((capture / (name + '-direct.rgba')).read_bytes()),
        'picture_pixel_differences': case['naturalPicturePixelMismatches'],
        'reserved_flag_pixel_differences': case['reserved']['originalNaturalPixelMismatches'],
    })
(destination / 'windows-reference.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps({'cases': len(manifest['cases']), 'verified_capture_hashes': verified,
                  'fixture_bytes': sum(path.stat().st_size for path in destination.iterdir() if path.is_file())}))
