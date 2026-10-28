#!/usr/bin/env python3
"""Independently test angular reduction against both native hole assays.

This proves angular membership on unchanged solid-red backgrounds, not the
general center detector or numerical per-bin reduction. All SDK statuses and
eight independently emitted output buffers are checked by the inverse analyzer.
"""
import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path


spec = importlib.util.spec_from_file_location('inverse', Path(__file__).with_name('analyze-redeye-inverse.py'))
inverse = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inverse)


def bucket(x, y, cx, cy):
    return int((math.degrees(math.atan2(y-cy, x-cx)) % 360) // 6)


def analyze(root):
    checked = inverse.analyze(root)
    manifest = json.loads((root/'generate.json').read_text())
    rows = []
    for item in manifest['cases']:
        name = item['name']
        width, height = item['direct']['width'], item['direct']['height']
        cx, cy = (width-1)/2, (height-1)/2
        rx, ry = cx, cy
        source = (root/('atlas-'+name+'.rgba')).read_bytes()
        observed = (root/item['direct']['rgba']).read_bytes()
        baseline = inverse.predicted(source,width,height,[])
        holes = item['sourceDefinition']['holes']
        inside = [h for h in holes if math.hypot((h[0]-cx)/rx,(h[1]-cy)/ry) < 1]
        affected = {bucket(h[0],h[1],cx,cy) for h in inside}
        mismatches = []
        points = changed = 0
        for y in range(height):
            for x in range(width):
                i = 4*(y*width+x)
                # Exclude every possible local circle, including cases where
                # none was actually detected. This avoids assuming a selector.
                if source[i:i+4] != bytes((240,20,10,255)) or \
                   math.hypot((x-cx)/rx,(y-cy)/ry) >= 1 or \
                   any(math.hypot(x-h[0],y-h[1]) < 7 for h in holes):
                    continue
                expected = bucket(x,y,cx,cy) in affected
                actual = max(abs(a-b) for a,b in zip(observed[i:i+4],baseline[i:i+4])) > 1
                points += 1
                changed += actual
                if expected != actual:
                    mismatches.append(dict(x=x,y=y,bin=bucket(x,y,cx,cy),expectedAffected=expected,
                                           observedAffected=actual,rgba=list(observed[i:i+4])))
        status = next(row for row in checked['cases'] if row['name'] == name)
        rows.append(dict(name=name,sourceSHA256=hashlib.sha256(source).hexdigest(),
                         rgbaSHA256=hashlib.sha256(observed).hexdigest(),
                         allEightObservationBuffersIdentical=status['allEightObservationBuffersIdentical'],
                         affectedBins=sorted(affected),testedPixelCount=points,
                         changedPixelCount=changed,mismatchCount=len(mismatches),mismatches=mismatches))
    return dict(artifact=str(root),cases=rows)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('inverse_artifact',type=Path)
    parser.add_argument('seed_artifact',type=Path)
    parser.add_argument('output',type=Path)
    args = parser.parse_args()
    artifacts = [analyze(args.inverse_artifact),analyze(args.seed_artifact)]
    cases = [row for artifact in artifacts for row in artifact['cases']]
    report = dict(qualification='Measured angular membership on the two solid-red hole assays. '
                  'The source/nonuniform center detector, chosen local seed and per-bin numerical function remain open. '
                  'No application pixel tolerance or approximate implementation follows from this analysis.',
                  formula='bin=floor((atan2(y-cy,x-cx)*180/pi mod360)/6); cx=(width-1)/2; cy=(height-1)/2',
                  excludedLocalCircleRadius=7,caseCount=len(cases),
                  testedPixelCount=sum(row['testedPixelCount'] for row in cases),
                  mismatchCount=sum(row['mismatchCount'] for row in cases),artifacts=artifacts)
    args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({key:report[key] for key in ('caseCount','testedPixelCount','mismatchCount')}))
