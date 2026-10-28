#!/usr/bin/env python3
"""Index retained RedEye oracles and their original source atlas for arithmetic work.

No source pixels, EMFs, expected outputs or tolerances are generated or changed.
The capture ZIP/member/source receipts remain the authority for atlas provenance.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fixture', type=Path)
    parser.add_argument('artifacts', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--context-overlay', type=Path)
    args = parser.parse_args()
    helper = Path(__file__).with_name('analyze-redeye-connected-geometry.py')
    spec = importlib.util.spec_from_file_location('geometry', helper)
    geometry = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(geometry)
    sources = geometry.source_index(args.artifacts)
    manifest_bytes = (args.fixture / 'windows-reference.json').read_bytes()
    manifest = json.loads(manifest_bytes)
    replacements = {}
    if args.context_overlay:
        overlay = json.loads(args.context_overlay.read_text())
        assert digest(manifest_bytes) == overlay['originalManifestSHA256']
        originals = {case['file']: case for case in manifest['cases']}
        for replacement in overlay['replacements']:
            old = originals[replacement['file']]
            fresh = replacement['case']
            assert replacement['file'] not in replacements
            assert old['sourceSHA256'] == replacement['sourceSHA256'] == fresh['sourceSHA256']
            assert old['referenceRGBA'] == replacement['previousReferenceRGBA']
            assert old['rgbaSHA256'] == replacement['previousRGBA_SHA256']
            assert digest((args.fixture / old['referenceRGBA']).read_bytes()) == old['rgbaSHA256']
            for field in ['file', 'family', 'parameters', 'width', 'height']:
                assert old[field] == fresh[field]
            assert digest((args.fixture / fresh['referenceRGBA']).read_bytes()) == fresh['rgbaSHA256']
            assert len(replacement['freshRepeats']) >= 3
            assert all(row['finalSHA256'] == row['intrinsicSHA256'] == fresh['rgbaSHA256']
                       for row in replacement['freshRepeats'])
            replacements[replacement['file']] = fresh
    rows = []
    for original_case in manifest['cases']:
        case = replacements.get(original_case['file'], original_case)
        if case['family'] != 'redEyeCorrection':
            continue
        original = (args.fixture / case['file']).read_bytes()
        assert digest(original) == case['sourceSHA256']
        assert case['sourceSHA256'] in sources, case['file']
        _, _, atlas = sources[case['sourceSHA256']]
        pixels = atlas.read_bytes()
        reference = args.fixture / case['referenceRGBA']
        expected = reference.read_bytes()
        assert len(pixels) == case['width'] * case['height'] * 4
        assert len(expected) == len(pixels)
        assert digest(expected) == case['rgbaSHA256']
        rows.append(dict(case=case, atlas=str(atlas.resolve()), reference=str(reference.resolve()),
                         sourceAtlasSHA256=digest(pixels), originalSHA256=digest(original),
                         referenceSHA256=digest(expected)))
    args.output.write_text(json.dumps(rows, indent=2) + '\n')
    print(json.dumps(dict(redEyeSourceCases=len(rows), freshContextMappings=len(replacements), output=str(args.output))))


if __name__ == '__main__':
    main()
