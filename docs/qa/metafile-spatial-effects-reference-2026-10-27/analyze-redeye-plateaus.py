#!/usr/bin/env python3
"""Compare original native angular plateaus; never generate application pixels.

This extends the low-mean component observations with high-red-fraction bins.
Equal histogram populations appearing in a central foreground and an inverse
hole atlas are compared without assuming the rational candidate is correct.
"""
import argparse
from collections import defaultdict
import hashlib
import importlib.util
import json
import math
from pathlib import Path

spec=importlib.util.spec_from_file_location('aggregation',Path(__file__).with_name('analyze-redeye-aggregation.py'))
aggregation=importlib.util.module_from_spec(spec);spec.loader.exec_module(aggregation)


def analyze(root, followup=False):
    manifest=json.loads((root/'generate.json').read_text())
    atlases={item['name']:item for item in manifest.get('atlases',[])}
    results=[]
    for item in manifest['cases']:
        if item.get('family')!='redEyeCorrection' or item['parameters']['areas']!=[[0,0,32,32]]:
            continue
        direct=item['direct']
        if direct['setParametersStatus']!=0 or direct['applyStatus']!=0:
            raise ValueError('SDK failure: '+item['name'])
        definition=item.get('sourceDefinition',{})
        if followup:
            if definition.get('shape') not in ('square','disk') or definition.get('foregroundRGB')!=[240,20,10]:
                continue
            cx=definition['left']+(definition['size']-1)/2
            cy=definition['top']+(definition['size']-1)/2
            if cx.is_integer() or cy.is_integer() or not (definition['left']<=15.5<definition['left']+definition['size'] and definition['top']<=15.5<definition['top']+definition['size']):
                continue
            source=(root/atlases[item['atlas']]['rgba']).read_bytes()
        else:
            cx=cy=15.5
            source=(root/('atlas-'+item['name']+'.rgba')).read_bytes()
        observed=(root/direct['rgba']).read_bytes()
        if len(source)!=4096 or len(observed)!=4096:
            raise ValueError('unexpected dimensions')
        bins=defaultdict(list)
        for y in range(32):
            for x in range(32):
                radius=math.hypot(x-cx,y-cy)/15.5
                if radius>=1:
                    continue
                index=int((math.degrees(math.atan2(y-cy,x-cx))%360)//6)
                offset=4*(32*y+x)
                bins[index].append((x,y,radius,source[offset:offset+4],observed[offset:offset+4]))
        for index,points in bins.items():
            foreground=[point for point in points if point[3]==bytes((240,20,10,255))]
            if not foreground or len(foreground)==len(points):
                continue
            # A constant least-corrected region at distinct radii is evidence
            # of a floor, rather than fitting a polynomial to the radial field.
            minimum_loss=min(240-point[4][0] for point in foreground)
            plateau=[point for point in foreground if 240-point[4][0]==minimum_loss]
            if len(plateau)<2 or max(point[2] for point in plateau)-min(point[2] for point in plateau)<.02:
                continue
            intervals=[aggregation.rounding_interval(point[4],point[3]) for point in plateau]
            lower=max(interval[0] for interval in intervals)
            upper=min(interval[1] for interval in intervals)
            if lower>upper:
                continue
            values=[max(0,point[3][0]-(point[3][1]+point[3][2])/2)/255 for point in points]
            mean=sum(values)/len(values)
            maximum=max(values)
            variance=sum((value-mean)**2 for value in values)/len(values)
            deficit_sum=sum(maximum-value for value in values)
            squared_deficit_sum=sum((maximum-value)**2 for value in values)
            rational=aggregation.floor_mask(mean)
            fifth=max(0,1-.4*(mean+mean**3+mean**5))
            results.append(dict(name=item['name'],bin=index,count=len(points),redCount=len(foreground),
                meanRedness=mean,minimumRedness=min(values),maximumRedness=maximum,
                populationVariance=variance,maximumDeficitSum=deficit_sum,
                squaredMaximumDeficitSum=squared_deficit_sum,
                strengthInterval=[lower,upper],maskInterval=[math.sqrt(max(0,lower)/220),math.sqrt(max(0,upper)/220)],
                plateauPixelCount=len(plateau),plateauRadiusRange=[min(point[2] for point in plateau),max(point[2] for point in plateau)],
                plateauPixels=[dict(x=point[0],y=point[1],rgba=list(point[4])) for point in plateau],
                sourceSHA256=hashlib.sha256(source).hexdigest(),rgbaSHA256=hashlib.sha256(observed).hexdigest(),
                candidates=dict(rationalStrength=220*rational*rational,
                                fifthOddStrength=220*fifth*fifth,
                                twicePopulationVarianceStrength=440*variance)))
    return dict(artifact=str(root),observations=results)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('followup',type=Path)
    parser.add_argument('inverse',type=Path)
    parser.add_argument('seed',type=Path)
    parser.add_argument('radial',type=Path)
    parser.add_argument('output',type=Path)
    args=parser.parse_args()
    artifacts=[analyze(args.followup,True)]+[analyze(path) for path in (args.inverse,args.seed,args.radial)]
    groups=defaultdict(list)
    for artifact in artifacts:
        for observation in artifact['observations']:
            # Exact sample histogram, including the intermediate low-red value.
            key=(observation['count'],observation['redCount'],round(observation['meanRedness'],14),round(observation['populationVariance'],14))
            groups[key].append(observation)
    rows=[]
    for key,observations in sorted(groups.items()):
        lower=max(item['strengthInterval'][0] for item in observations)
        upper=min(item['strengthInterval'][1] for item in observations)
        first=observations[0]
        rows.append(dict(count=key[0],redCount=key[1],meanRedness=first['meanRedness'],populationVariance=first['populationVariance'],
            strengthInterval=[lower,upper],allObservationsCompatible=lower<=upper,
            observationCount=len(observations),caseNames=sorted({item['name'] for item in observations}),
            candidates=first['candidates']))
    report=dict(qualification='Native statistical component analysis only. Least-corrected repeated pixels at distinct radii are plateau evidence, not a general mask implementation. No fitted candidate is promoted to production. Native raw sources/outputs remain unchanged.',
        plateauCriterion='at least two least-red-loss source-red pixels in the same six-degree bin, normalized-radius spread >=0.02, with intersecting all-RGB rounding intervals',
        groupCount=len(rows),observationCount=sum(len(a['observations']) for a in artifacts),
        incompatibleHistogramGroups=sum(not item['allObservationsCompatible'] for item in rows),groups=rows,artifacts=artifacts)
    args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({key:report[key] for key in ('groupCount','observationCount','incompatibleHistogramGroups')}))
