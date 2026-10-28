#!/usr/bin/env python3
"""Evaluate a source-mean-only mixture extension against angular plateaus.

This is a component hypothesis. It neither chooses angular geometry nor composes
native radial/glint fields, and cannot enable the general application effect.
No coefficients are fitted. This algebraically extends the binary component
using source means, and separately tests whether variance was identifiable.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path


def reduction(samples,pixel):
    # Algebraic two-population extension of the earlier binary RGB formula.
    # Only source channel means are used: no variance, fitted coefficient or
    # observed native floor enters this independent hypothesis.
    means=[sum(p[k]for p in samples)/len(samples)for k in range(3)]
    zi=max(0,pixel[0]-(pixel[1]+pixel[2])/2)
    mu=max(0,means[0]-(means[1]+means[2])/2)
    h=(zi-mu)/zi if zi>0 else 0
    if h<=0:return dict(strength=0,linearExcess=h,meanRGB=means)
    dg,db=means[1]-pixel[1],means[2]-pixel[2]
    denominator=means[1]*(abs(dg)*means[2]+abs(db)*means[1])
    extra=(1-h)*abs(dg)*dg*db/denominator if denominator>0 else 0
    return dict(strength=max(0,pixel[0]-max(pixel[1:3]))*max(0,h+extra),
                linearExcess=h,meanRGB=means,mixtureExtra=extra)


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
        if case['group']not in ('source-color','neutral-glint-intensity','activation-redness','first-min-vs-eligible'):
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
            h='(z_pixel-max(0,meanR-(meanG+meanB)/2))/z_pixel',
            delta='dG=meanG-G_pixel; dB=meanB-B_pixel',
            strength='M*max(0,h+(1-h)*abs(dG)*dG*dB/(meanG*(abs(dG)*meanB+abs(dB)*meanG)))'),
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
