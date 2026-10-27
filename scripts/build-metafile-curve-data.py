#!/usr/bin/env python3
"""Package the complete, independently observed native ColorCurve byte domain."""
import argparse
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[1]
DOMAINS = [(mode, -255 if mode < 2 else -100 if mode < 6 else 1 if mode == 6 else 0,
            255 if mode < 2 else 100 if mode < 6 else 255 if mode == 6 else 254)
           for mode in range(8)]

def sha(data):
    return hashlib.sha256(data).hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact', type=Path)
    parser.add_argument('--run-id', type=int, required=True)
    parser.add_argument('--artifact-id', type=int, required=True)
    parser.add_argument('--archive-sha256', required=True)
    args = parser.parse_args()
    assert len(args.archive_sha256) == 64 and all(c in '0123456789abcdef' for c in args.archive_sha256)
    source_rows = json.loads((args.artifact / 'curve-domain-input-hashes.json').read_text(encoding='utf-8-sig'))
    source_names = {
        'docs/qa/metafile-pointwise-effects-reference-2026-10-27/CurveLookupReference.cpp',
        'docs/qa/metafile-pointwise-effects-reference-2026-10-27/PointwiseEffectsReference.cpp',
        'docs/qa/metafile-pointwise-effects-reference-2026-10-27/make-endpoint-variants.py',
        '.github/workflows/metafile-pointwise-effects-curve-domain-reference.yml',
    }
    source_proof = []
    for row in source_rows:
        if row['file'] not in source_names:
            continue
        raw = (ROOT / row['file']).read_bytes()
        lf = raw.replace(b'\r\n', b'\n')
        native_hash = row['sha256'].lower()
        assert native_hash in {sha(raw), sha(lf.replace(b'\n', b'\r\n'))}, row['file']
        source_proof.append({'file': row['file'], 'git_lf_sha256': sha(lf),
                             'native_checkout_sha256': native_hash,
                             'native_checkout_line_endings': 'LF' if native_hash == sha(lf) else 'CRLF'})
    assert {row['file'] for row in source_proof} == source_names
    source_commit = (args.artifact / 'curve-domain-source-revision.txt').read_text(encoding='utf-8-sig').strip()
    assert len(source_commit) == 40 and all(c in '0123456789abcdef' for c in source_commit)
    observed = []
    for version in (1, 2):
        manifest = json.loads((args.artifact / f'lookup-v{version}.json').read_text())
        assert manifest['startupVersion'] == version
        assert manifest['caseCount'] == 2336 and manifest['bytes'] == 598016
        rows = manifest['cases']
        assert len(rows) == 2336
        index = 0
        for mode, low, high in DOMAINS:
            for intensity in range(low, high + 1):
                row = rows[index]
                assert (row['adjustment'], row['adjustValue'], row['offset'], row['length']) == (mode, intensity, index * 256, 256)
                assert len(row['channels']) == 4
                for channel, result in enumerate(row['channels']):
                    assert result['channel'] == channel
                    assert result['setParametersStatus'] == result['applyStatus'] == 0
                    assert result['auxBytes'] == 1024
                    assert result['routingErrors'] == result['actualPixelErrors'] == 0
                index += 1
        filename = manifest['binary']
        assert filename == f'lookup-v{version}.bin'
        raw = (args.artifact / filename).read_bytes()
        assert len(raw) == 598016
        observed.append(raw)
    assert observed[0] == observed[1], 'Native startup versions differ; do not silently select a profile.'
    data = b'TGCCLUT1' + struct.pack('<II', 2336, 256) + observed[0]
    assert len(data) == 598032
    folder = ROOT / 'Sources/TurtleGitMetafile/Resources'
    folder.mkdir(parents=True, exist_ok=True)
    metadata = {
        'format': 'TGCCLUT1: eight ASCII bytes, little-endian UInt32 table count and byte width, then native channel tables',
        'table_count': 2336, 'table_bytes': 256, 'bytes': len(data), 'sha256': sha(data),
        'domains': [{'adjustment': mode, 'minimum': low, 'maximum': high} for mode, low, high in DOMAINS],
        'native_windows_run': args.run_id, 'native_windows_artifact': args.artifact_id,
        'archive_sha256': args.archive_sha256, 'native_startup_versions_identical': [1, 2],
        'raw_native_bytes_sha256': sha(observed[0]),
        'native_capture_source_commit': source_commit, 'native_capture_sources': source_proof,
        'proof': 'Every integer intensity in all eight valid domains; every input byte; all four channel masks, auxiliary routing and actual native pixels checked. No interpolation or captured-parameter subset.',
        'excluded_wire_endpoints': 'White saturation 0 and black saturation 255 are SDK-refused but paint the ordinary image through Bitmap(file,FALSE), measured separately.',
        'source': 'Original TurtleGit Windows SDK observation; no third-party implementation code copied.'
    }
    (folder / 'color-curves.bin').write_bytes(data)
    (folder / 'color-curves.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(f'Packaged complete curve domain: {len(data)} bytes, SHA256 {sha(data)}')

if __name__ == '__main__':
    main()
