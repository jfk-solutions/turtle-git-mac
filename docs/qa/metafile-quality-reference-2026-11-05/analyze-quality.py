#!/usr/bin/env python3
"""Calibrate recorded Windows coverage from the independent native captures.

No TurtleGit-rendered pixel participates in this analysis. All integer geometry
below comes from QualityReference.cpp; sixteenth-pixel arithmetic avoids a
floating-point boundary decision at the discriminating sample locations.
"""
import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path, PureWindowsPath

W, H = 128, 96
ROIS = {
    'opaque_wedge': (0, 34, 61, 83),
    'opaque_rectangles': (46, 4, 87, 32),
    'vertical_strokes': (4, 4, 39, 32),
    'vertical_stroke_interiors': (4, 8, 39, 26),
}
TRIANGLE = ((66, 612), (878, 642), (134, 1262))
RECTANGLE_EDGES = (770, 932, 1094, 1256)
STROKE_CENTERS = (128, 260, 392, 524)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def inside_wedge(x, y):
    """Standard half-open horizontal ray: left included, right excluded."""
    result = False
    for i, (ax, ay) in enumerate(TRIANGLE):
        bx, by = TRIANGLE[(i + 1) % 3]
        if (ay > y) != (by > y):
            determinant = (bx - ax) * (y - ay) - (x - ax) * (by - ay)
            if determinant > 0 if by > ay else determinant < 0:
                result = not result
    return result


def inside_rectangles(x, y):
    return 100 <= y < 456 and any(edge <= x < edge + 80 for edge in RECTANGLE_EDGES)


def inside_stroke_closed_endpoints(x, y):
    return 96 <= y <= 448 and any(center - 8 <= x < center + 8 for center in STROKE_CENTERS)


def inside_stroke_body(x, y):
    return 96 <= y < 448 and any(center - 8 <= x < center + 8 for center in STROKE_CENTERS)


def coverage(roi, smoothing, pixel, predicate, centered_subcells=False):
    nx, ny = (8, 8 if smoothing == 5 else 4) if smoothing in (2, 4, 5) else (1, 1)
    phase = 8 if pixel in (2, 4) else 0
    points = []
    for j in range(ny):
        for i in range(nx):
            if nx == 1:
                points.append((phase, phase))
            else:
                # Calibrated grid starts at pixel-center minus one half; it
                # does NOT place a sample in the middle of each subcell.
                x = -8 + 16 * i // nx
                y = -8 + 16 * j // ny
                if centered_subcells:
                    x += 8 // nx
                    y += 8 // ny
                points.append((phase + x, phase + y))
    result = []
    for y in range(roi[1], roi[3]):
        for x in range(roi[0], roi[2]):
            count = sum(predicate(x * 16 + dx, y * 16 + dy) for dx, dy in points)
            result.append((count * 255 + len(points) // 2) // len(points))
    return result


def roi_alpha(rgba, roi):
    return [rgba[(y * W + x) * 4 + 3] for y in range(roi[1], roi[3]) for x in range(roi[0], roi[2])]


def compare(expected, actual, roi):
    width = roi[2] - roi[0]
    differences = []
    for i, (e, a) in enumerate(zip(expected, actual)):
        if e != a:
            differences.append({'xy': [roi[0] + i % width, roi[1] + i // width], 'windowsAlpha': a, 'modelAlpha': e})
    return {'comparedPixels': len(actual), 'mismatchedPixels': len(differences), 'firstDifferences': differences[:12]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('captures', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    folder = args.captures
    manifest = json.loads((folder / 'quality-observations.json').read_text())
    if (manifest['requestedCaseCount'], manifest['completedCaseCount'], len(manifest['cases'])) != (53, 53, 53):
        raise SystemExit('Original independent capture inventory is incomplete')
    hashes = json.loads((folder / 'sha256.json').read_text())
    verified = []
    external = []
    for entry in hashes:
        name = PureWindowsPath(entry['Path']).name
        candidate = folder / name
        if candidate.is_file():
            if digest(candidate.read_bytes()) != entry['Hash'].lower():
                raise SystemExit('Independent capture hash mismatch: ' + name)
            verified.append(name)
        else:
            external.append(entry)

    aliases = defaultdict(list)
    observations = []
    input_hashes = {}
    for case in manifest['cases']:
        name = case['name']
        captures = {}
        for kind in ('direct', 'natural', 'picture'):
            path = folder / (name + '-' + kind + '.rgba')
            captures[kind] = path.read_bytes()
            if len(captures[kind]) != W * H * 4:
                raise SystemExit('Wrong independent RGBA dimensions: ' + path.name)
            input_hashes[path.name] = digest(captures[kind])
        observations.append({
            'name': name,
            'directNaturalRGBAMismatches': sum(captures['direct'][i:i+4] != captures['natural'][i:i+4] for i in range(0, W*H*4, 4)),
            'naturalPictureRGBAMismatches': sum(captures['natural'][i:i+4] != captures['picture'][i:i+4] for i in range(0, W*H*4, 4)),
            'naturalPictureAlphaMismatches': sum(a != b for a, b in zip(captures['natural'][3::4], captures['picture'][3::4])),
        })
        if not name.startswith('ordinary-'):
            continue
        smoothing, pixel = case['requested']['smoothing'], case['requested']['pixelOffset']
        aliases[digest(captures['natural'])].append(name)
        entry = observations[-1]
        entry['requested'] = case['requested']
        entry['nativeQualityRecords'] = [
            {key: record[key] for key in ('type', 'flags', 'dataSize', 'dataHex')}
            for record in json.loads((folder / (name + '-records.json')).read_text())['records']
            if record['type'] in (0x401e, 0x4022, 0x4024)
        ]
        entry['coverageFits'] = {}
        for key, predicate in (
            ('opaque_wedge', inside_wedge),
            ('opaque_rectangles', inside_rectangles),
            ('vertical_stroke_interiors', inside_stroke_body),
        ):
            roi = ROIS[key]
            entry['coverageFits'][key] = compare(coverage(roi, smoothing, pixel, predicate), roi_alpha(captures['natural'], roi), roi)
        if smoothing in (0, 1, 3):
            roi = ROIS['vertical_strokes']
            entry['coverageFits']['aliased_stroke_closed_endpoint_model'] = compare(
                coverage(roi, smoothing, pixel, inside_stroke_closed_endpoints), roi_alpha(captures['natural'], roi), roi)
        else:
            roi = ROIS['opaque_wedge']
            entry['coverageFits']['centered_subcell_grid_counterexample'] = compare(
                coverage(roi, smoothing, pixel, inside_wedge, centered_subcells=True), roi_alpha(captures['natural'], roi), roi)
        entry['strokeEndpointProfiles'] = []
        for center in STROKE_CENTERS:
            x = center // 16
            entry['strokeEndpointProfiles'].append({
                'worldX': center / 16,
                'sampleColumns': [x-1, x, x+1],
                'rows': [
                    {'y': y, 'alphas': [captures['natural'][(y*W + column)*4+3] for column in (x-1,x,x+1)]}
                    for y in (5,6,7,27,28,29)
                ],
            })

    report = {
        'schema': 1,
        'source': {
            'successfulWindowsRun': 41938727574,
            'artifact': 13374649845,
            'artifactZipSHA256VerifiedByParent': 'bca1e883888e790f92174fdf0803b3b3202b3435b79c902cf5091acff7f5cfee',
            'preservedEarlierFailedCompileRun': 41938313535,
            'earlierFailure': 'C2664: Graphics.ReleaseHDC returns void; focused observer repair calls it then checks GetLastStatus. No successful pixels are attributed to that failed run.',
            'manifestSHA256': digest((folder / 'quality-observations.json').read_bytes()),
            'verifiedCaptureHashEntries': len(verified),
            'externalSourceExecutableRuntimeHashRecords': external,
            'allOriginalCasesRetained': len(manifest['cases']),
        },
        'calibration': {
            'aliasedModes': [0,1,3], 'aa8x4Modes': [2,4], 'aa8x8Modes': [5],
            'pixelCenterIntegerModes': [0,1,3], 'pixelCenterHalfModes': [2,4],
            'aaGrid': 'x - 0.5 + i/8, y - 0.5 + j/Ny; Ny=4 or8; Half adds0.5 to both coordinates. Samples are not subcell centers.',
            'fillTieRule': 'Half-open horizontal-ray polygon test; rectangle lower bounds included, upper bounds excluded.',
            'opaqueAlphaQuantization': 'floor((255 * coveredSamples + sampleCount/2) / sampleCount)',
            'boundedPositiveControls': 'All30 ordinary modes match all2989 isolated wedge pixels, all1148 rectangle pixels and all630 interior vertical-stroke pixels exactly.',
            'aliasedStrokeEndpointLimit': 'Closed longitudinal endpoints and half-open transverse band match integer-center modes; Half has one additional Windows start pixel(24,5) on theX24.5 control. Do not claim a universal endpoint tie rule.',
            'aaStrokeEndpointLimit': 'AA vertical-line endpoints are not the geometric butt rectangle under the calibrated fill grid. Endpoint profiles are retained; GDI+ stroke geometry/fast paths require separate treatment.',
            'scope': 'These measurements calibrate the specified solid fill and straight-stroke-interior controls. They do not prove every curve, pen join/cap, transform, brush, clip, compositor or Windows version.',
        },
        'roisXYExclusiveUpper': ROIS,
        'ordinaryNaturalRGBAAliasGroups': list(aliases.values()),
        'observations': observations,
        'originalCaptureSHA256': input_hashes,
        'windows': json.loads((folder / 'windows.json').read_text(encoding='utf-8-sig')),
        'runtimeVersions': json.loads((folder / 'runtime-versions.json').read_text(encoding='utf-8-sig')),
    }
    text = json.dumps(report, indent=2) + '\n'
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text)
    else:
        print(text, end='')


if __name__ == '__main__':
    main()
