#!/usr/bin/env python3
"""Quantify the native inverse-hole discriminator; this is not a pixel oracle.

The source SDK observations remain untouched. The circle hypothesis deliberately
reports its failures, and compares first-seed and all-seed versions independently.
It does not establish a general detector or permit an application tolerance.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path


def digest(data):
    return hashlib.sha256(data).hexdigest()


def predicted(source, width, height, holes):
    result = bytearray(source)
    for y in range(height):
        for x in range(width):
            i = 4*(y*width+x)
            r, g, b = source[i:i+3]
            m = max(0, r-max(g, b))
            q = max(0., 1.-math.hypot((x-(width-1)/2)/((width-1)/2),
                                     (y-(height-1)/2)/((height-1)/2)))
            strength = max([m*q*q/4] + [max(0, m-5*((x-h[0])**2+(y-h[1])**2)) for h in holes])
            for channel, value in enumerate((r-11*strength/16, g+5*strength/16, b+5*strength/16)):
                result[i+channel] = max(0, min(255, math.floor(value+.5)))
    return result


def errors(actual, expected, source, width):
    failures = []
    for i in range(0, len(actual), 4):
        delta = [abs(a-b) for a, b in zip(actual[i:i+4], expected[i:i+4])]
        if max(delta) > 1:
            failures.append(dict(x=(i//4)%width, y=(i//4)//width,
                                 source=list(source[i:i+4]), predicted=list(actual[i:i+4]),
                                 observed=list(expected[i:i+4]), maxAbsDelta=max(delta)))
    return dict(maxAbsDelta=max(abs(a-b) for a, b in zip(actual, expected)),
                pixelsExceedingOne=len(failures),
                absoluteErrorSum=sum(abs(a-b) for a, b in zip(actual, expected)), failures=failures)


def analyze(root):
    manifests = {name: json.loads((root/(name+'.json')).read_text())
                 for name in ('generate', 'direct-v1', 'replay', 'replay-v1')}
    generated = manifests['generate']
    rows = []
    for item in [generated['baseline']] + generated['cases']:
        name = item['name']
        inputs = (root/('atlas-'+name+'.rgba')).read_bytes()
        requested = (root/('atlas-'+name+'-requested.rgba')).read_bytes()
        width, height = item['direct']['width'], item['direct']['height']
        if len(inputs) != 4*width*height or inputs != requested:
            raise ValueError('actual/requested source mismatch: '+name)
        observations = []
        for key, manifest in manifests.items():
            group = [manifest['baseline']] + manifest['cases']
            observed = next(row for row in group if row['atlas'] == item['atlas'])
            if key in ('generate', 'direct-v1'):
                for field in ('direct', 'created'):
                    record = observed[field]
                    if record['setParametersStatus'] != 0 or record['applyStatus'] != 0:
                        raise ValueError('SDK failure: '+key+'/'+name+'/'+field)
                    observations.append((key+'/'+field, (root/record['rgba']).read_bytes()))
                if key == 'generate' and any(observed[field] != 0 for field in
                        ('recordSetParametersStatus', 'recordCreateStatus', 'recordStatus')):
                    raise ValueError('record failure: '+name)
            else:
                if observed['bitmapLoadStatus'] != 0 or observed['drawStatus'] != 0 or not observed['expectedSize']:
                    raise ValueError('file consumer failure: '+key+'/'+name)
                observations.append((key, (root/observed['rgba']).read_bytes()))
                observations.append((key+'/intrinsic', (root/observed['intrinsic']['rgba']).read_bytes()))
        reference = observations[0][1]
        holes = item['sourceDefinition']['holes']
        gray_holes = [h for h in holes if h[2] == h[3] == h[4]]
        eligible_holes = [h for h in gray_holes if 5 <= h[0] < width-5 and 5 <= h[1] < height-5]
        row = dict(name=name, sourceSHA256=digest(inputs), nativeSHA256=digest(reference),
                   allEightObservationBuffersIdentical=all(data == reference for _, data in observations),
                   observationHashes={key:digest(data) for key, data in observations},
                   sourceDefinition=item['sourceDefinition'])
        row['uniformOnly'] = errors(predicted(inputs,width,height,[]),reference,inputs,width)
        row['firstEligibleGraySeed'] = errors(predicted(inputs,width,height,eligible_holes[:1]),reference,inputs,width)
        row['everyEligibleGraySeed'] = errors(predicted(inputs,width,height,eligible_holes),reference,inputs,width)
        # Describe the unexplained component without fitting or subtracting it.
        # The four rays point inward from corner-side 2x2 blocks. They are not
        # a claim that a general detector samples only these diagonals.
        hole_points = {(h[0], h[1]) for h in holes}
        quadrants = {'topLeft': [], 'topRight': [], 'bottomLeft': [], 'bottomRight': []}
        outside_rays = []
        for failure in row['firstEligibleGraySeed']['failures']:
            x, y = failure['x'], failure['y']
            if (x, y) in hole_points:
                continue
            u, v = min(x, width-1-x), min(y, height-1-y)
            on_ray = u == v or (u in (5, 6) and v in (5, 6))
            if not on_ray:
                outside_rays.append([x, y])
            quadrant = ('top' if y < height/2 else 'bottom') + ('Left' if x < width/2 else 'Right')
            quadrants[quadrant].append([x, y])
        row['unexplainedResidualGeometry'] = dict(quadrantPoints=quadrants,
                                                 nonSourcePointsOutsideInwardDiagonalRays=outside_rays)
        rows.append(row)
    return dict(qualification='Numerical discriminator, not an accepted general RedEye implementation. '
                'The five-pixel seed inset and first-seed choice are unproven hypotheses; '
                'the diagonal residual and arbitrary-image detector remain unresolved.',
                circleFormula='S=max(M*Q^2/4, M-5*((x-hx)^2+(y-hy)^2)); M=max(0,R-max(G,B)); '
                'output=round(R-11*S/16,G+5*S/16,B+5*S/16,A)', cases=rows)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    report = analyze(args.artifact)
    args.output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps([dict(name=r['name'], buffersIdentical=r['allEightObservationBuffersIdentical'],
                          firstSeedBadPixels=r['firstEligibleGraySeed']['pixelsExceedingOne'],
                          allSeedBadPixels=r['everyEligibleGraySeed']['pixelsExceedingOne']) for r in report['cases']]))
