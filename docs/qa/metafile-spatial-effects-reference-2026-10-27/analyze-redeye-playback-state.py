#!/usr/bin/env python3
"""Compare unchanged retained RedEye wires across native process contexts.

This reads observations only. It never changes an oracle, invokes Windows,
executes external research code, or generates an expected pixel.
"""
import argparse
import hashlib
import json
from pathlib import Path


def sha(data):
    return hashlib.sha256(data).hexdigest()


def differences(left, right):
    assert len(left) == len(right) == 4096
    values = [abs(a-b) for a, b in zip(left, right)]
    return dict(exact=not any(values), maxByteDelta=max(values),
                pixelsExceedingOne=sum(max(values[i:i+4]) > 1 for i in range(0, len(values), 4)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('fixture', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    manifest = json.loads((args.fixture / 'windows-reference.json').read_text())
    cases = {case['file']: case for case in manifest['cases']}
    inputs = json.loads((args.capture / 'retained-inputs.json').read_text(encoding='utf-8-sig'))['cases']
    groups = {}
    for item in inputs:
        name = item['file']
        case = cases[name]
        assert case['sourceSHA256'] == item['sha256']
        assert sha((args.fixture / name).read_bytes()) == item['sha256']
        assert sha((args.capture / name).read_bytes()) == item['sha256']
        expected = (args.fixture / case['referenceRGBA']).read_bytes()
        assert sha(expected) == case['rgbaSHA256'] == item['retainedReferenceSHA256']
        groups[name] = dict(sourceSHA256=item['sha256'], oldReferenceSHA256=sha(expected),
                            observations=[], freshFinalSHA256=[])
    observations = []
    manifests = sorted(args.capture.glob('fresh-*.json')) + sorted(args.capture.glob('sequence-*.json'))
    assert len(manifests) == 11
    for path in manifests:
        process = json.loads(path.read_text(encoding='utf-8-sig'))
        assert process['startupVersion'] == 1 and process['startupStatus'] == 0
        assert len(process['cases']) == process['caseCount']
        for case in process['cases']:
            name = case['file']
            assert name in groups and case['bitmapLoadStatus'] == case['drawStatus'] == 0
            expected = (args.fixture / cases[name]['referenceRGBA']).read_bytes()
            stages = {stage: (args.capture / case[stage]['rgba']).read_bytes() for stage in ['intrinsic', 'final']}
            assert stages['intrinsic'] == stages['final']
            fresh = process['label'].startswith('fresh-')
            final_sha = sha(stages['final'])
            if fresh:
                groups[name]['freshFinalSHA256'].append(final_sha)
            row = dict(label=process['label'], processID=process['processID'], order=case['order'],
                       freshProcess=fresh, intrinsicEqualsFinal=True, finalSHA256=final_sha,
                       deltaFromOld=differences(stages['final'], expected))
            groups[name]['observations'].append(row)
            observations.append((name, stages['final'], row))
    assert len(observations) == 15
    for name, group in groups.items():
        assert len(group['freshFinalSHA256']) == 3 and len(set(group['freshFinalSHA256'])) == 1
        group['freshFinalSHA256'] = group['freshFinalSHA256'][0]
        baseline = next(data for wire, data, row in observations if wire == name and row['freshProcess'])
        for wire, data, row in observations:
            if wire == name:
                row['deltaFromFresh'] = differences(data, baseline)
        group['uniqueFinalHashes'] = sorted({row['finalSHA256'] for row in group['observations']})
    result = dict(qualification='Bounded native process-context observations; no claim of random nondeterminism or an identified memory mechanism. Old oracles are unchanged.',
                  sourceRevision=(args.capture/'source-revision.txt').read_text(encoding='utf-8-sig').strip(),
                  processCount=len(manifests), playbackCount=len(observations), intrinsicEqualsFinalCount=15,
                  freshRepeatCountPerWire=3, sourceCases=groups)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({name: dict(freshSHA256=g['freshFinalSHA256'], distinctOutputs=len(g['uniqueFinalHashes'])) for name, g in groups.items()}))


if __name__ == '__main__':
    main()
