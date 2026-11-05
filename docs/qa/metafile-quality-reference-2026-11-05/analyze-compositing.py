#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Analyze independent GDI+ quality captures; never render with TurtleGit."""
import argparse
import hashlib
import json
import math
from pathlib import Path


def decode(value):
    value /= 255
    return value / 12.92 if value <= .04045 else ((value + .055) / 1.055) ** 2.4


def encode(value):
    value = 12.92 * value if value <= .0031308 else 1.055 * value ** (1 / 2.4) - .055
    return max(0, min(255, int(value * 255 + .5)))


LINEAR13 = [int(decode(value) * 8192 + .5) for value in range(256)]
ENCODED13 = [encode(value / 8192) for value in range(8193)]


def gamma13(source, destination, alpha):
    return [ENCODED13[(LINEAR13[s] * alpha + LINEAR13[d] * (255 - alpha)) // 255]
            for s, d in zip(source, destination)]


def floating(source, destination, alpha):
    return [encode((decode(s) * alpha + decode(d) * (255 - alpha)) / 255)
            for s, d in zip(source, destination)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('captures', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    root = args.captures
    observations = json.loads((root / 'quality-observations.json').read_text())
    width, height = observations['width'], observations['height']
    if (width, height) != (128, 96):
        raise SystemExit('The independently authored probe regions require the original 128x96 scene.')
    hashes = {}

    def raw(name, kind):
        name = name + '-' + kind + '.rgba'
        data = (root / name).read_bytes()
        if len(data) != width * height * 4:
            raise SystemExit('Unexpected RGBA size: ' + name)
        hashes[name] = hashlib.sha256(data).hexdigest()
        return data

    def pixel(data, x, y):
        offset = (y * width + x) * 4
        return list(data[offset:offset + 4])

    def differences(lhs, rhs):
        return sum(lhs[p:p + 4] != rhs[p:p + 4] for p in range(0, len(lhs), 4))

    modes = {}
    records = {}
    for prefix in ['compositing-quality-', 'source-copy-compositing-quality-']:
        family = {}
        for mode in range(5):
            name = prefix + str(mode)
            family[mode] = {kind: raw(name, kind) for kind in ['direct', 'natural', 'picture']}
            report = json.loads((root / (name + '-records.json')).read_text())
            records[name] = [record['flags'] for record in report['records'] if record['type'] == 0x4024]
        modes[prefix] = family
    over, copy = modes['compositing-quality-'], modes['source-copy-compositing-quality-']
    source = copy[2]['natural']
    expected = over[2]['natural']
    models = {'integer-linear13': gamma13, 'floating-linear': floating}
    counts = {name: {'pixels': 0, 'mismatchedPixels': 0, 'maximumChannelDifference': 0} for name in models}
    unique = set()
    # Red before the ellipse/blue, and green right of the red before the blue:
    # every qualifying pixel has exactly one translucent paint over the opaque
    # authored background. SourceCopy exposes its real quantized straight RGBA.
    for left, top, right, bottom in [(10, 12, 38, 35), (82, 20, 109, 38)]:
        for y in range(top, bottom):
            for x in range(left, right):
                straight = pixel(source, x, y)
                alpha = straight[3]
                if alpha in (0, 255):
                    continue
                actual = pixel(expected, x, y)
                if actual[3] != 255:
                    raise SystemExit('Probe is no longer over the opaque authored background.')
                unique.add((tuple(straight), tuple(actual)))
                for name, model in models.items():
                    result = model(straight[:3], [32, 64, 96], alpha)
                    delta = [abs(a - b) for a, b in zip(result, actual[:3])]
                    counts[name]['pixels'] += 1
                    counts[name]['mismatchedPixels'] += any(delta)
                    counts[name]['maximumChannelDifference'] = max(counts[name]['maximumChannelDifference'], *delta)
    green = pixel(source, 90, 30)
    blue = pixel(source, 90, 70)
    layers = []
    for name, paint, destination, xy in [
        ('green-over-red', green, pixel(expected, 15, 15), (60, 45)),
        ('blue-over-green', blue, pixel(expected, 90, 30), (90, 70)),
    ]:
        result = gamma13(paint[:3], destination[:3], paint[3])
        actual = pixel(expected, *xy)[:3]
        layers.append(dict(name=name, xy=xy, predictedRGB=result, actualRGB=actual, equal=result == actual))
    transparent = []
    for xy in [(4, 4), (4, 10), (10, 4), (5, 5)]:
        plain = pixel(over[0]['natural'], *xy)
        actual = pixel(expected, *xy)
        alpha13 = plain[3] * 8192 // 255
        predicted = alpha13 * 255 // 8192
        transparent.append(dict(xy=xy, plainRGBA=plain, gammaRGBA=actual,
                                predictedFixedAlpha=predicted, equal=predicted == actual[3]))
    copy_edge = pixel(source, 10, 20)
    result = {
        'schema': 1,
        'scope': 'Independent native-recorded Windows RGBA analysis; no production renderer invoked.',
        'wireCompositingQualityFlags': records,
        'sourceOver': {
            'defaultHighSpeedAssumeLinearEqual': over[0]['natural'] == over[1]['natural'] == over[4]['natural'],
            'highQualityGammaCorrectedEqual': over[2]['natural'] == over[3]['natural'],
            'directNaturalDifferences': {str(q): differences(over[q]['direct'], over[q]['natural']) for q in range(5)},
            'naturalPictureDifferences': {str(q): differences(over[q]['natural'], over[q]['picture']) for q in range(5)},
        },
        'sourceCopy': {
            'allQualitiesEqual': all(copy[q][kind] == copy[0]['natural'] for q in range(5) for kind in ['direct', 'natural', 'picture']),
        },
        'isolatedQuantizedGammaProbes': counts,
        'uniqueProbePairs': len(unique),
        'multipleOpaqueLayerProbes': layers,
        'transparentDestinationBackgroundEdgeProbes': transparent,
        'sourceCopyPartialCoverageProbe': {
            'xy': [10, 20],
            'priorDestinationAlpha': 255,
            'intrinsicSourceAlpha': 129,
            'geometricCoverage': '8/32',
            'observedSourceCopyRGBA': copy_edge,
            'incorrectFractionalDestinationFadeAlpha': 32 + (255 * 24 + 16) // 32,
            'meaning': 'GDI+ overwrites the covered pixel with its AA source; it does not retain destination opacity at that fractional edge.',
        },
        'profile': 'Floor integer unpremultiplication; nearest sRGB decode to 0..8192; integer-floor weighted blend; nearest sRGB encode.',
        'limits': [
            'These probes do not uniquely distinguish 8191 versus 8192 or every intermediate precision choice.',
            'The chosen 8192 range also follows Microsoft PixelFormat documentation of the GDI+ 16-bit channel range 0..2^13.',
            'Opaque-destination color and transparent-destination background-edge alpha are calibrated; general partially transparent destinations remain uncertified.',
            'Natural and Picture gamma edge RGB differ; direct/natural equality does not certify every outer image replay.',
        ],
        'inputSHA256': hashes,
    }
    text = json.dumps(result, indent=2) + '\n'
    if args.output:
        args.output.write_text(text)
    else:
        print(text, end='')


if __name__ == '__main__':
    main()
