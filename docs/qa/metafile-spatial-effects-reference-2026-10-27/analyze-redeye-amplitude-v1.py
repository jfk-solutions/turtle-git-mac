#!/usr/bin/env python3
"""Falsify source-only RedEye amplitude selectors against original FILE-v1 bytes.

All reported selectors are unaccepted hypotheses. No observed pixel or inferred
coefficient is fed into prediction. The .66 literal is explicitly the proposed
SDK-constant hypothesis, not a derived constant or a production implementation.
Geometry, angular reduction and glint are supplied independent hypotheses; a
failure can falsify their composition without identifying which component failed.
"""
import argparse
from collections import Counter, defaultdict
import hashlib
import importlib.util
import json
import math
from pathlib import Path

spec=importlib.util.spec_from_file_location('mean_extension',Path(__file__).with_name('analyze-redeye-mean-extension.py'))
mean=importlib.util.module_from_spec(spec);spec.loader.exec_module(mean)


def sha(data):return hashlib.sha256(data).hexdigest()

def rgb_strength_interval(pixel,observed):
    r,g,b,_=pixel;rr,gg,bb,_=observed
    return max((r-rr-.5)*16/11,(gg-g-.5)*16/5,(bb-b-.5)*16/5),min((r-rr+.5)*16/11,(gg-g+.5)*16/5,(bb-b+.5)*16/5)

def case(root,item,atlas,references):
    name=item['name'];source=(root/atlas[item['atlas']]['rgba']).read_bytes();reference=references.get(name)
    if reference is None:return dict(name=name,skipped='No FILE-v1 reference for atlas')
    if reference['bitmapLoadStatus']!=0 or reference['drawStatus']!=0 or not reference['expectedSize']:return dict(name=name,skipped='Native FILE-v1 failed')
    observed=(root/reference['rgba']).read_bytes();width=reference['width'];height=reference['height']
    if len(source)!=4*width*height or len(observed)!=len(source):return dict(name=name,skipped='Nonmatching framing')
    areas=item['parameters']['areas']
    if len(areas)!=1:return dict(name=name,skipped='Multiple ROI composition not isolated')
    left,top,right,bottom=areas[0]
    if not(0<=left<right<=width and 0<=top<bottom<=height):return dict(name=name,skipped='Outside ROI has separate no-paint contract')
    if any(source[i+3]!=255 for i in range(0,len(source),4)):return dict(name=name,skipped='Nonopaque composition not isolated')
    cx=(left+right-1)/2;cy=(top+bottom-1)/2;radius=min((right-left-1)/2,(bottom-top-1)/2)
    if radius<=0:return dict(name=name,skipped='Degenerate radius')
    bins=defaultdict(list);points={};hist=Counter()
    for y in range(top,bottom):
      for x in range(left,right):
        p=tuple(source[4*(y*width+x):4*(y*width+x)+4]);hist[p]+=1
        rho=math.hypot((x-cx)/radius,(y-cy)/radius)
        if rho>=1:continue
        k=int((math.degrees(math.atan2(y-cy,x-cx))%360)//6)
        bins[k].append(p);points[x,y]=(rho,k,p)
    reductions={(k,p):mean.reduction(samples,p)for k,samples in bins.items()for p in set(samples)}
    mixed=sum(len(set(samples))>1 for samples in bins.values())
    seed=None;best=math.inf
    for y in range(top,bottom):
      for x in range(left,right):
        r,g,b,a=source[4*(y*width+x):4*(y*width+x)+4]
        if g and r/g<best:best=r/g;seed=(x,y)
    eligible=seed is not None and math.hypot((seed[0]-cx)/radius,(seed[1]-cy)/radius)<=2/3
    lower=-math.inf;upper=math.inf;informative=0;sectors=set();outside_changes=0;sector_intervals={}
    policies=('quarter','three-quarter','any-mixed-sdk-literal','majority-mixed-sdk-literal','majority-mixed-source-contrast','majority-mixed-sdk-literal-pure255')
    scores={policy:dict(maxByteDelta=0,pixelsExceedingOne=0,changedChannels=0)for policy in policies}
    first_fail={policy:[]for policy in policies}
    for y in range(height):
      for x in range(width):
        offset=4*(y*width+x);p=list(source[offset:offset+4]);actual=list(observed[offset:offset+4])
        strengths={policy:0 for policy in policies}
        if (x,y)in points:
          rho,k,_=points[x,y];parts=reductions[k,tuple(p)];h=parts['linearExcess'];q=1-rho;m=max(0,p[0]-max(p[1:3]));floor=parts['strength']
          glint=max(0,m-5*((x-seed[0])**2+(y-seed[1])**2))if eligible else 0
          lo,hi=rgb_strength_interval(p,actual)
          if m>0 and 1-h>0 and q>0 and lo>max(floor,glint)+1:
            clo=(lo/m-h)/((1-h)*q*q);chi=(hi/m-h)/((1-h)*q*q)
            lower=max(lower,clo);upper=min(upper,chi);informative+=1;sectors.add(k)
            row=sector_intervals.setdefault(k,dict(count=len(bins[k]),positiveRedCount=sum(p[0]>max(p[1:3])for p in bins[k]),meanRGB=parts['meanRGB'],lower=-math.inf,upper=math.inf,informativePixels=0))
            row['lower']=max(row['lower'],clo);row['upper']=min(row['upper'],chi);row['informativePixels']+=1
          contrast=.75*max(0,p[0]-max(p[1:3]))/(p[0]+min(p[1:3])) if p[0]+min(p[1:3])>0 else 0
          coefficients={'quarter':.25,'three-quarter':.75,'any-mixed-sdk-literal':.66 if mixed else .25,'majority-mixed-sdk-literal':.66 if 2*mixed>len(bins)else .25,'majority-mixed-source-contrast':contrast if 2*mixed>len(bins)else .25,'majority-mixed-sdk-literal-pure255':.75 if p[:3]==[255,0,0]else(.66 if 2*mixed>len(bins)else .25)}
          for policy,c in coefficients.items():strengths[policy]=max(floor,glint,m*(h+(1-h)*c*q*q))
        elif actual!=p:outside_changes+=1
        for policy in policies:
          predicted=mean.corrected(p,strengths[policy])if(x,y)in points else p
          differences=[abs(a-b)for a,b in zip(actual,predicted)];delta=max(differences);score=scores[policy]
          score['maxByteDelta']=max(score['maxByteDelta'],delta);score['pixelsExceedingOne']+=delta>1;score['changedChannels']+=sum(d>0 for d in differences)
          if delta>1 and len(first_fail[policy])<3:first_fail[policy].append(dict(x=x,y=y,source=p,predicted=predicted,native=actual))
    for k,row in sector_intervals.items():
        local=bytearray();native=bytearray()
        for (x,y),(_,bin_index,pixel) in points.items():
            if bin_index!=k:continue
            local.extend(x.to_bytes(4,'little'));local.extend(y.to_bytes(4,'little'));local.extend(pixel)
            native.extend(observed[4*(y*width+x):4*(y*width+x)+4])
        row['sourceSectorSHA256']=sha(local);row['nativeSectorSHA256']=sha(native)
    bounds=dict(interval=[lower,upper]if informative else None,informativePixels=informative,informativeSectors=len(sectors),consistent=informative>0 and lower<=upper)
    return dict(name=name,sourceSHA256=sha(source),fileV1SHA256=sha(observed),dimensions=[width,height],roi=areas[0],sourceHistogram=[dict(rgba=list(p),count=n)for p,n in sorted(hist.items())],sourceStatistics=dict(ellipsePixels=len(points),positiveRedPixels=sum(p[0]>max(p[1:3])for _,_,p in points.values()),angularBins=len(bins),mixedAngularBins=mixed,majorityMixed=2*mixed>len(bins)),candidateSeed=seed,candidateSeedEligible=eligible,changedPixelsOutsideSuppliedCircle=outside_changes,conditionalCoefficient=bounds,conditionalSectorCoefficients=sector_intervals,predictions={p:dict(**scores[p],firstFailures=first_fail[p])for p in policies})

def analyze(roots):
    artifacts=[]
    for root in roots:
        gm=json.loads((root/'generate.json').read_text(encoding='utf-8-sig'));replay=json.loads((root/'replay-v1.json').read_text(encoding='utf-8-sig'))
        atlas={a['name']:a for a in gm['atlases']};refs={a['name'].removeprefix('replay-v1-'):a for a in replay['cases']}
        if 'baseline'in replay:refs[replay['baseline']['name'].removeprefix('replay-v1-')]=replay['baseline']
        items=([gm['baseline']]if'baseline'in gm else[])+gm['cases']
        rows=[case(root,c,atlas,refs)for c in items if c.get('family','redEyeCorrection')=='redEyeCorrection']
        artifacts.append(dict(path=str(root),generateSHA256=sha((root/'generate.json').read_bytes()),replayV1SHA256=sha((root/'replay-v1.json').read_bytes()),cases=rows))
    cases=[c for a in artifacts for c in a['cases']if'predictions'in c]
    identical=defaultdict(list);counterexamples=[]
    for a in artifacts:
        for c in a['cases']:
            for k,row in c.get('conditionalSectorCoefficients',{}).items():
                if row['lower']>row['upper']:continue
                key=(tuple(c['dimensions']),tuple(c['roi']),k,row['sourceSectorSHA256'])
                for old in identical[key]:
                    if row['lower']>old['interval'][1] or old['interval'][0]>row['upper']:
                        counterexamples.append(dict(qualification='Conditional coefficient intervals are disjoint despite identical supplied-geometry sector coordinates/RGBA; global geometry/selection/glint can still be responsible.',sector=k,sourceSectorSHA256=row['sourceSectorSHA256'],first=old,second=dict(artifact=a['path'],name=c['name'],interval=[row['lower'],row['upper']],nativeSectorSHA256=row['nativeSectorSHA256'])))
                identical[key].append(dict(artifact=a['path'],name=c['name'],interval=[row['lower'],row['upper']],nativeSectorSHA256=row['nativeSectorSHA256']))
    policy_summary={p:dict(fullBufferPasses=sum(c['predictions'][p]['pixelsExceedingOne']==0 for c in cases),failingCases=sum(c['predictions'][p]['pixelsExceedingOne']>0 for c in cases),pixelsExceedingOne=sum(c['predictions'][p]['pixelsExceedingOne']for c in cases),maxByteDelta=max(c['predictions'][p]['maxByteDelta']for c in cases))for p in cases[0]['predictions']}
    return dict(qualification='Source-only mathematical falsification, not Core/native/rendering acceptance. All predictions use supplied ROI/min-radius-circle geometry, existing mean-extension angular floor and candidate glint. None is an accepted general model. No fixtures or production code are changed.',observationMode='replay-v1',constantQualification='The .66 literal is an explicitly proposed SDK-literal hypothesis from prior conditional constraints, not a derived constant. The contrast expression .75*(R-max(G,B))/(R+min(G,B)) is an independent color-ratio hypothesis. No inferred output coefficient, observed RGB or fixture name chooses a prediction.',selectorDefinitions={'any-mixed-sdk-literal':'C=.66 iff any of 60 occupied angular bins contains distinct RGB; otherwise.25','majority-mixed-sdk-literal':'C=.66 iff more than half occupied angular bins contain distinct RGB; otherwise.25','majority-mixed-source-contrast':'Replace .66 by source-pixel contrast expression, retain same majority selector','majority-mixed-sdk-literal-pure255':'Same majority SDK-literal selector, with explicit unaccepted source-pixel RGB255/0/0 ->C=.75 branch'},caseCount=len(cases),skippedCases=sum('skipped'in c for a in artifacts for c in a['cases']),fullBufferPixels=sum(c['dimensions'][0]*c['dimensions'][1]for c in cases),policySummary=policy_summary,identicalSectorDisjointIntervalCount=len(counterexamples),identicalSectorCounterexamples=counterexamples[:40],artifacts=artifacts)

if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('output',type=Path);p.add_argument('artifacts',type=Path,nargs='+');a=p.parse_args();report=analyze(a.artifacts);a.output.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:report[k]for k in('caseCount','skippedCases','fullBufferPixels','policySummary')}))
