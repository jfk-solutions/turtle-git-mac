#!/usr/bin/env python3
"""Evaluate a natural RGB moment candidate against original angular plateaus.

This is a component hypothesis. It neither chooses angular geometry nor composes
native radial/glint fields, and cannot enable the general application effect.
No coefficients are fitted: the positive excess is normalized by the exact
Bhatia-Davis variance bound; RGB covariance uses relative standard deviations.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path


def reduction(samples,pixel):
    n=len(samples)
    means=[sum(p[k]for p in samples)/n for k in range(3)]
    variances=[sum((p[k]-means[k])**2 for p in samples)/n for k in range(3)]
    cov=sum((p[1]-means[1])*(p[2]-means[2])for p in samples)/n
    values=[max(0,p[0]-(p[1]+p[2])/2)for p in samples]
    mu=sum(values)/n;variance=sum((v-mu)**2 for v in values)/n
    zi=max(0,pixel[0]-(pixel[1]+pixel[2])/2)
    denominator=(max(values)-mu)*(mu-min(values))
    if zi<=mu or zi<=0 or denominator<=0:
        return dict(strength=0,linearExcess=0,dispersion=0,coefficient=0,enhancement=1)
    dispersion=math.sqrt(max(0,min(1,variance/denominator)))
    h=(zi-mu)/zi*dispersion
    relative_g=math.sqrt(variances[1])/means[1] if means[1]>0 else 0
    relative_b=math.sqrt(variances[2])/means[2] if means[2]>0 else 0
    c=relative_g/(relative_g+relative_b) if relative_g+relative_b>0 else 0
    enhancement=1+c*cov/(means[1]*means[2]) if means[1]*means[2]>0 else 1
    strength=max(0,pixel[0]-max(pixel[1:3]))*h*max(0,enhancement)
    return dict(strength=strength,linearExcess=(zi-mu)/zi,dispersion=dispersion,
                coefficient=c,enhancement=enhancement,meanRedness=mu,populationVariance=variance)


def corrected(pixel,strength):
    return [max(0,min(255,math.floor(value+.5))) for value in
            (pixel[0]-11*strength/16,pixel[1]+5*strength/16,pixel[2]+5*strength/16)]+[255]


def analyze(plateaus,detector):
    old=json.loads(plateaus.read_text());new=json.loads(detector.read_text())
    rows=[]
    for artifact in old['artifacts']:
        for q in artifact['observations']:
            n,k=q['count'],q['redCount']
            low=abs(q['meanRedness']-225/255*k/n)>1e-8
            samples=[(240,20,10)]*k+[(96,96,96)]*(n-k-int(low))+([(128,20,10)]if low else[])
            source=[240,20,10,255];result=reduction(samples,source)
            predicted=corrected(source,result['strength'])
            errors=[max(abs(a-b)for a,b in zip(predicted,p['rgba'])) for p in q['plateauPixels']]
            rows.append(dict(artifact=artifact['artifact'],name=q['name'],bin=q['bin'],count=n,redCount=k,
                sourceRGBA=source,predictedRGBA=predicted,**result,
                allRGBStrengthInterval=q['strengthInterval'],maxByteDelta=max(errors),
                comparedPixelCount=len(errors),pixelsExceedingOne=sum(e>1 for e in errors)))
    for case in new['cases']:
        if case['group']not in ('source-color','neutral-glint-intensity','activation-redness'):
            continue
        for q in case.get('suppliedROIOriginStatisticalConstraints',[]):
            if not q['repeatedPlateauAtDistinctRadii']:continue
            samples=[]
            for item in q['rgbHistogram']:samples += [item['rgba'][:3]]*item['count']
            source=case['sourceDefinition']['backgroundRGBA'];result=reduction(samples,source)
            predicted=corrected(source,result['strength'])
            errors=[max(abs(a-b)for a,b in zip(predicted,p['nativeFileRGBA']))for p in q['plateauPixels']]
            rows.append(dict(artifact='detector43/native file',name=case['name'],bin=q['bin'],count=q['count'],
                sourceRGBA=source,predictedRGBA=predicted,**result,
                allRGBStrengthInterval=q['plateauStrengthInterval'],maxByteDelta=max(errors),
                comparedPixelCount=len(errors),pixelsExceedingOne=sum(e>1 for e in errors)))
    return dict(qualification='Unaccepted angular component hypothesis only. No geometry, radial composition, alpha or general-image parity follows. Exact original SDK/file bytes remain the oracles; this report never writes fixtures or expected image pixels.',
        formulas=dict(z='max(0,R-(G+B)/2)',
            h='max(0,(z_pixel-meanZ)/z_pixel)*sqrt(varianceZ/((maxZ-meanZ)*(meanZ-minZ)))',
            c='(sigmaG/meanG)/(sigmaG/meanG+sigmaB/meanB)',
            enhancement='1+c*Cov(G,B)/(meanG*meanB)',
            strength='max(0,R-max(G,B))*h*max(0,enhancement)'),
        inputSHA256={str(path):hashlib.sha256(path.read_bytes()).hexdigest() for path in (plateaus,detector)},
        observationCount=len(rows),comparedPixelCount=sum(r['comparedPixelCount']for r in rows),
        maxByteDelta=max(r['maxByteDelta']for r in rows),pixelsExceedingOne=sum(r['pixelsExceedingOne']for r in rows),
        cases=rows)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('plateaus',type=Path);parser.add_argument('detector',type=Path);parser.add_argument('output',type=Path)
    args=parser.parse_args();report=analyze(args.plateaus,args.detector)
    args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({key:report[key]for key in ('observationCount','comparedPixelCount','maxByteDelta','pixelsExceedingOne')}))
