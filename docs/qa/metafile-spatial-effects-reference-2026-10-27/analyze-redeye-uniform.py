#!/usr/bin/env python3
"""Test the independently derived uniform-input RedEye cone hypothesis.

This is a numerical analysis of original SDK outputs, not the application pixel
oracle. Nonuniform images are deliberately not claimed by the hypothesis.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path


def analyze(root):
    manifest = json.loads((root / 'generate.json').read_text())
    atlas = {item['name']: item for item in manifest['atlases']}
    rows = []
    for item in manifest['cases']:
        if item['family'] != 'redEyeCorrection':
            continue
        if item['name'].endswith('-repeat'):
            continue
        areas = item['parameters']['areas']
        if len(areas) != 1:
            continue
        left, top, right, bottom = areas[0]
        direct = item.get('direct', {})
        if direct.get('setParametersStatus') != 0 or direct.get('applyStatus') != 0:
            raise ValueError('native status failure: ' + item['name'])
        width, height = direct['width'], direct['height']
        source = (root / atlas[item['atlas']]['rgba']).read_bytes()
        expected = (root / direct['rgba']).read_bytes()
        if len(source) != width*height*4 or len(expected) != len(source):
            raise ValueError('native RGBA framing')
        if any(source[i+3] != 255 for i in range(0, len(source), 4)):
            raise ValueError('hypothesis requires opaque input')
        if not (0 <= left < right <= width and 0 <= top < bottom <= height):
            continue
        colors = {tuple(source[(y*width+x)*4:(y*width+x)*4+4]) for y in range(top, bottom) for x in range(left, right)}
        if len(colors) != 1:
            continue
        actual = bytearray(source)
        cx, cy = (left+right-1)/2, (top+bottom-1)/2
        rx, ry = (right-left-1)/2, (bottom-top-1)/2
        if rx <= 0 or ry <= 0:
            continue
        for y in range(max(0, top), min(height, bottom)):
            for x in range(max(0, left), min(width, right)):
                q = max(0., 1. - math.hypot((x-cx)/rx, (y-cy)/ry))
                mask = q/2
                i = (y*width+x)*4
                r, g, b = source[i:i+3]
                m = max(0, r-max(g, b)) * mask * mask
                actual[i] = max(0, min(255, math.floor(r-11*m/16+.5)))
                actual[i+1] = max(0, min(255, math.floor(g+5*m/16+.5)))
                actual[i+2] = max(0, min(255, math.floor(b+5*m/16+.5)))
        errors = [abs(a-b) for a, b in zip(actual, expected)]
        rows.append(dict(name=item['name'], parameters=item['parameters'], width=width, height=height,
                         sourceSHA256=hashlib.sha256(source).hexdigest(),
                         observedRGBA=direct['rgba'], observedSHA256=hashlib.sha256(expected).hexdigest(),
                         changedChannelCount=sum(delta != 0 for delta in errors),
                         maxAbsDelta=max(errors), absoluteErrorSum=sum(errors)))
    return dict(model='Opaque spatially uniform source, single nondegenerate ROI only',
                formula='cx=(left+right-1)/2; rx=(right-left-1)/2; likewiseY; Q=max(0,1-hypot((x-cx)/rx,(y-cy)/ry)); mask=Q/2; M=max(0,R-max(G,B))*mask^2; output=round(R-11*M/16,G+5*M/16,B+5*M/16,A)',
                qualification='Exact observed uniform profile does not establish nonuniform image correction. Strict original nonuniform oracles remain unchanged.',
                caseCount=len(rows), maxAbsDelta=max((r['maxAbsDelta'] for r in rows), default=0),
                changedChannelCount=sum(r['changedChannelCount'] for r in rows), cases=rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    result = analyze(args.artifact)
    args.output.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({key: result[key] for key in ['caseCount', 'maxAbsDelta', 'changedChannelCount']}))


if __name__ == '__main__':
    main()
