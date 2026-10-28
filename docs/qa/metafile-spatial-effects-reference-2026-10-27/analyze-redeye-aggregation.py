#!/usr/bin/env python3
"""Test the natural angular-mean floor component on original SDK observations.

This does not choose a detector center, infer a radial formula, or produce an
application oracle. It explicitly records noncentral failures and uniform-color
counterexamples to applying the floor as a complete image effect.
"""
import argparse
import hashlib
import json
import math
from collections import defaultdict
from pathlib import Path


def rounding_interval(rgba, source):
    r,g,b,_ = source
    rr,gg,bb,_ = rgba
    return (max((r-rr-.5)*16/11,(gg-g-.5)*16/5,(bb-b-.5)*16/5),
            min((r-rr+.5)*16/11,(gg-g+.5)*16/5,(bb-b+.5)*16/5))


def floor_mask(mean):
    return max(0,1-.4*mean/(1-mean*mean)) if mean<1 else 0


def analyze(root):
    manifest=json.loads((root/'generate.json').read_text())
    atlases={row['name']:row for row in manifest['atlases']}
    rows=[]
    groups=defaultdict(list)
    uniform_counterexamples=[]
    for item in manifest['cases']:
        if item['family']!='redEyeCorrection' or item['parameters']['areas']!=[[0,0,32,32]]:
            continue
        if item['direct']['setParametersStatus']!=0 or item['direct']['applyStatus']!=0:
            raise ValueError('native SDK failure: '+item['name'])
        source=(root/atlases[item['atlas']]['rgba']).read_bytes()
        observed=(root/item['direct']['rgba']).read_bytes()
        if len(source)!=4096 or len(observed)!=4096:
            raise ValueError('unexpected observation dimensions')
        definition=item.get('sourceDefinition',{})
        if len({source[i:i+4] for i in range(0,len(source),4)})==1:
            r,g,b,_=source[:4]
            score=max(0,r-(g+b)/2)/255
            change=max(0,r-max(g,b))*floor_mask(score)**2
            predicted=round(r-11*change/16)
            if abs(predicted-observed[0])>1:
                uniform_counterexamples.append(dict(name=item['name'],sourceRGBA=list(source[:4]),
                    nativeTopLeftRGBA=list(observed[:4]),rawFloorPredictedRed=predicted))
            continue
        if definition.get('shape') not in ('square','disk') or \
           definition.get('foregroundRGB')!=[240,20,10] or definition.get('backgroundRGB')!=[96,96,96]:
            continue
        cx=definition['left']+(definition['size']-1)/2
        cy=definition['top']+(definition['size']-1)/2
        # A foreground center exactly on a source pixel has an unresolved
        # central-pixel assignment; do not disguise that as bin zero evidence.
        if cx.is_integer() and cy.is_integer():
            rows.append(dict(name=item['name'],qualification='center coincides with source pixel; assignment unresolved'))
            continue
        central=definition['left']<=15.5<definition['left']+definition['size'] and \
                definition['top']<=15.5<definition['top']+definition['size']
        bins=defaultdict(list)
        for y in range(32):
            for x in range(32):
                if math.hypot((x-cx)/15.5,(y-cy)/15.5)>=1:
                    continue
                index=int((math.degrees(math.atan2(y-cy,x-cx))%360)//6)
                bins[index].append((x,y))
        checked=[]
        for index,points in bins.items():
            values=[]
            intervals=[]
            red_count=0
            for x,y in points:
                i=4*(y*32+x)
                r,g,b,a=source[i:i+4]
                if a!=255:
                    raise ValueError('opaque proof received nonopaque input')
                values.append(max(0,r-(g+b)/2)/255)
                if (r,g,b)==(240,20,10):
                    red_count+=1
                    intervals.append(rounding_interval(observed[i:i+4],source[i:i+4]))
            if not 0<red_count<len(points):
                continue
            lower=max(value[0] for value in intervals)
            upper=min(value[1] for value in intervals)
            if lower>upper:
                continue # Native radial variation; not an observed constant floor.
            mean=sum(values)/len(values)
            mask=floor_mask(mean)
            strength=220*mask*mask
            entry=dict(bin=index,count=len(points),redCount=red_count,meanRedness=mean,
                       populationVariance=sum((v-mean)**2 for v in values)/len(values),
                       predictedMask=mask,predictedStrength=strength,
                       allRGBRoundingInterval=[lower,upper],exactRoundingCompatible=lower<=strength<=upper)
            checked.append(entry)
            if central:
                groups[(len(points),red_count)].append(entry)
        rows.append(dict(name=item['name'],sourceSHA256=hashlib.sha256(source).hexdigest(),
                         rgbaSHA256=hashlib.sha256(observed).hexdigest(),center=[cx,cy],
                         centralForegroundContainsROICenter=central,constantBinObservations=checked))
    group_rows=[]
    for (count,red_count),entries in sorted(groups.items()):
        group_rows.append(dict(count=count,redCount=red_count,observations=len(entries),
                               allExactRoundingCompatible=all(row['exactRoundingCompatible'] for row in entries)))
    return dict(qualification='Component proof only. Supplied foreground-bounds center is an analytic input, '
                'not an implemented detector. Noncentral cases are retained as counterevidence. '
                'Uniform counterexamples prohibit using this floor by itself; composition remains unresolved. '
                'Low-mean observations do not uniquely distinguish the rational expression from a finite '
                'odd-power expansion; high-red-fraction behavior is not established.',
                score='max(0,R-(G+B)/2)/255',
                floor='max(0,1-0.4*mean/(1-mean^2)); limit at mean=1 is zero',
                centralGroupCount=len(group_rows),
                centralObservationCount=sum(row['observations'] for row in group_rows),
                centralExactRoundingFailureCount=sum(not row['exactRoundingCompatible']
                    for row in rows if row.get('centralForegroundContainsROICenter')
                    for row in row['constantBinObservations']),
                centralGroups=group_rows,uniformStandaloneCounterexamples=uniform_counterexamples,cases=rows)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact',type=Path)
    parser.add_argument('output',type=Path)
    args=parser.parse_args()
    report=analyze(args.artifact)
    args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({key:report[key] for key in ('centralGroupCount','centralObservationCount',
                                                'centralExactRoundingFailureCount')}))
