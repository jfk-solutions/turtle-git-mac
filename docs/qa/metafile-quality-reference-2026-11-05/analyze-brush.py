#!/usr/bin/env python3
"""Reproduce brush color calibration using only the independent Windows pixels.

No TurtleGit-rendered image is an expected input. The ROI is wholly inside the
opaque rectangle in QualityReference.cpp, away from its fractional outer edge.
"""
import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path, PureWindowsPath

W, H = 128, 96
ROI = (5, 5, 124, 92)
START, END = (220, 20, 40), (30, 70, 230)
BACK, FORE = (230, 200, 20), (30, 40, 220)
TILE = (((240, 20, 30), (30, 220, 40)), ((30, 60, 230), (230, 210, 30)))


def linear(x, offset):
    # t=(x+phase)/128; sixteen intervals. Round their endpoint colors to
    # bytes FIRST, then interpolate within the interval and round again.
    coordinate = 2 * x + (1 if offset == 4 else 0)
    interval, fraction16 = divmod(coordinate, 16)
    result = []
    for start, end in zip(START, END):
        low = (start * 16 + (end - start) * interval + 8) // 16
        high = (start * 16 + (end - start) * (interval + 1) + 8) // 16
        result.append((low * (16 - fraction16) + high * fraction16 + 8) // 16)
    return tuple(result) + (255,)


def texture(x, y):
    # Inverse of explicit brush translation(.25,.5), at INTEGER device
    # coordinates. Periodic neighbors cross the tile seam, not transparent SVG
    # image bounds. All pixels in this fixture are opaque, so alpha remains255.
    x0, tx = divmod(4 * x - 1, 4)
    y0, ty = divmod(2 * y - 1, 2)
    weights = ((4-tx)*(2-ty), tx*(2-ty), (4-tx)*ty, tx*ty)
    points = (TILE[y0 % 2][x0 % 2], TILE[y0 % 2][(x0+1) % 2],
              TILE[(y0+1) % 2][x0 % 2], TILE[(y0+1) % 2][(x0+1) % 2])
    return tuple((sum(point[channel] * weight for point, weight in zip(points, weights)) + 4) // 8 for channel in range(3)) + (255,)


def hatch_color(coverage, floor):
    values = [a * (1-coverage) + b * coverage for a, b in zip(BACK, FORE)]
    return tuple(math.floor(v if floor else v + .5) for v in values) + (255,)


def rgba(data, x, y):
    return tuple(data[(y*W+x)*4:(y*W+x)*4+4])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('captures', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    folder = args.captures
    manifest = json.loads((folder/'quality-observations.json').read_text())
    if manifest['completedCaseCount'] != 53 or len(manifest['cases']) != 53:
        raise SystemExit('Independent capture inventory is incomplete')
    sha = {PureWindowsPath(row['Path']).name: row['Hash'].lower() for row in json.loads((folder/'sha256.json').read_text())}
    report = {'schema': 1, 'successfulWindowsRun': 41938727574,
              'preservedEarlierFailedCompileRun': 41938313535,
              'scope': 'Opaque interior only; source color/alpha and texture pixels are those in QualityReference.cpp. No renderer output used.',
              'roiXYExclusiveUpper': ROI, 'cases': []}
    all_data = {}
    for kind in ('linear', 'hatch', 'texture'):
        for offset in (3,4):
            name = f'brush-{kind}-p{offset}'
            file = name + '-natural.rgba'
            data = (folder/file).read_bytes()
            if len(data) != W*H*4 or hashlib.sha256(data).hexdigest() != sha[file]:
                raise SystemExit('Independent capture identity mismatch: '+file)
            all_data[(kind, offset)] = data
            colors = Counter(rgba(data,x,y) for y in range(ROI[1],ROI[3]) for x in range(ROI[0],ROI[2]))
            mismatches = []
            if kind != 'hatch':
                for y in range(ROI[1],ROI[3]):
                    for x in range(ROI[0],ROI[2]):
                        expected = linear(x,offset) if kind == 'linear' else texture(x,y)
                        actual = rgba(data,x,y)
                        if expected != actual:
                            mismatches.append({'xy':[x,y], 'windows':actual, 'model':expected})
            entry = {'name':name, 'rgbaSHA256':sha[file], 'pixels':sum(colors.values()),
                     'uniqueColors':[{'rgba':color,'pixels':count} for color,count in sorted(colors.items())],
                     'colorModelMismatchedPixels':len(mismatches), 'firstDifferences':mismatches[:8]}
            if kind == 'hatch':
                entry['colorModelMismatchedPixels'] = None  # Palette quantization only; geometric phase is not fitted here.
                floor_palette = {hatch_color(c, True) for c in (0,.25,math.sqrt(2)-.5)}
                rounded_palette = {hatch_color(c, False) for c in (0,.25,math.sqrt(2)-.5)}
                entry['floorPaletteUnexplainedPixels'] = sum(count for color,count in colors.items() if color not in floor_palette)
                entry['roundPaletteUnexplainedPixels'] = sum(count for color,count in colors.items() if color not in rounded_palette)
                entry['centralCoverageCandidatesNotDistinguished'] = {
                    'existingMeasuredSqrt2MinusHalf':hatch_color(math.sqrt(2)-.5,True),
                    'byteCoverage233Over255':hatch_color(233/255,True)}
            report['cases'].append(entry)
    report['pixelOffsetColorDifferences'] = {
        kind:sum(rgba(all_data[(kind,3)],x,y) != rgba(all_data[(kind,4)],x,y)
                 for y in range(ROI[1],ROI[3]) for x in range(ROI[0],ROI[2]))
        for kind in ('linear','hatch','texture')}
    report['rules'] = {
        'linear':'Sixteen factor intervals. Byte-round each channel at both interval endpoints, interpolate the local fraction, then byte-round again. t=(x+phase)/128; phase0 forNone,phase.5 forHalf.',
        'hatch':'For the measured opaque colors, floor channels after coverage mixing; the existing .25 and sqrt2−.5 coverage palette yields exact observed RGB. The fixture does not identify sqrt2−.5 versus233/255 coverage uniquely, nor calibrate semitransparent hatch rounding.',
        'texture':'Periodic bilinear at integer device coords transformed by brush inverse(.25,.5); wrap all neighbors across the2×2 seam. This gives oddX131/171/59 and evenX134/84/106,alpha255 independent ofY/PixelOffset.',
        'limits':'The texture fixture distinguishes this periodic bilinear result from nearest-neighbor and transparent SVG-tile seam filtering; it does not certify every image, interpolation kernel, transform or alpha combination. Hatch geometric phase is not rederived here.'}
    text = json.dumps(report,indent=2)+'\n'
    if args.output:
        args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(text)
    else:
        print(text,end='')


if __name__=='__main__':
    main()
