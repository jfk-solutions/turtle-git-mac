#!/usr/bin/env python3
"""Full-buffer falsification of RGB histogram/radial composition candidates.

This writes diagnostics only. Native FILE observations are never rewritten.
The histogram is computed directly from actual source RGBA, not observed floor
strengths or fixture-family constants. ROI origin, eligibility and seed choice
remain separately qualified hypotheses; alternate cone factors are reported
uniformly for every case, never selected by its name or observed pixels.
"""
import argparse
from collections import defaultdict
import hashlib
import json
import math
from pathlib import Path
import importlib.util
spec=importlib.util.spec_from_file_location("rgb",Path(__file__).with_name("analyze-redeye-rgb-dispersion.py"))
rgb=importlib.util.module_from_spec(spec);spec.loader.exec_module(rgb)


def digest(data):return hashlib.sha256(data).hexdigest()


def angle_degrees(dx,dy,policy):
    if policy=='atan2':return math.degrees(math.atan2(dy,dx))%360
    ax,ay=abs(dx),abs(dy)
    if ax+ay==0:return 0
    # Standard endpoint-matched Taylor/Hermite approximations, never fitted
    # against native observations. These only falsify angle-precision theories.
    t=(ay-ax)/(ay+ax)
    if policy=='endpoint-linear':a=math.pi*t/4
    elif policy=='endpoint-cubic':a=t+(math.pi/4-1)*t**3
    else:a=t-t**3/3+(math.pi/4-2/3)*t**5
    a+=math.pi/4
    if dx<0:a=math.pi-a
    if dy<0:a=-a
    return math.degrees(a)%360


def analyze_case(root,item,replays,geometry,signed_excess,center_policy,angle_policy,observation_mode="replay-v1"):
    name=item['name'];width=item.get('sourceWidth',item['direct']['width']);height=item.get('sourceHeight',item['direct']['height'])
    source=(root/('atlas-'+item['atlas']+'.rgba')).read_bytes()
    if len(source)!=width*height*4:raise ValueError('source size '+name)
    references=[]
    for mode,manifest in replays.items():
        candidates=manifest.get('cases',[])+([manifest['baseline']]if 'baseline'in manifest else [])
        ref=next(row for row in candidates if row['atlas']==item['atlas'])
        if ref['bitmapLoadStatus']!=0 or ref['drawStatus']!=0 or not ref['expectedSize']:raise ValueError('file failure '+name)
        references.append((mode,(root/ref['rgba']).read_bytes()))
    if any(len(data)!=len(source)for _,data in references):raise ValueError('file size '+name)
    observed=dict(references)[observation_mode]
    areas=item['parameters']['areas']
    if len(areas)!=1:return dict(name=name,skipped='multiple ROI composition not isolated')
    left,top,right,bottom=areas[0];left=max(0,left);top=max(0,top);right=min(width,right);bottom=min(height,bottom)
    if left>=right or top>=bottom:return dict(name=name,skipped='empty clipped area')
    cx=(left+right-1)/2;cy=(top+bottom-1)/2;rx=(right-left-1)/2;ry=(bottom-top-1)/2
    if geometry=='min-radius-circle':rx=ry=min(rx,ry)
    if rx<=0 or ry<=0:return dict(name=name,skipped='degenerate ellipse')
    initial_center=[cx,cy];center_iterations=[]
    if center_policy!='roi':
        for iteration in range(32 if center_policy=='iterative-positive-centroid'else 1):
            points=[]
            for y in range(top,bottom):
                for x in range(left,right):
                    offset=4*(y*width+x);r,g,b,a=source[offset:offset+4]
                    weight=max(0,r-(g+b)/2)
                    if weight<=0:continue
                    if center_policy in ('ellipse-positive-centroid','iterative-positive-centroid')and math.hypot((x-cx)/rx,(y-cy)/ry)>=1:continue
                    points.append((x,y,weight))
            if not points:break
            if center_policy=='positive-bounds':
                nx=(min(p[0]for p in points)+max(p[0]for p in points))/2
                ny=(min(p[1]for p in points)+max(p[1]for p in points))/2
            else:
                weight=sum(p[2]for p in points)
                nx=sum(p[0]*p[2]for p in points)/weight;ny=sum(p[1]*p[2]for p in points)/weight
            center_iterations.append(dict(x=nx,y=ny,count=len(points)))
            difference=math.hypot(nx-cx,ny-cy);cx,cy=nx,ny
            if difference<1e-10:break
    bins=defaultdict(list);coords={}
    for y in range(top,bottom):
        for x in range(left,right):
            rho=math.hypot((x-cx)/rx,(y-cy)/ry)
            if rho>=1:continue
            index=int(angle_degrees(x-cx,y-cy,angle_policy)//6)
            pixel=tuple(source[4*(y*width+x):4*(y*width+x)+4])
            bins[index].append(pixel);coords[x,y]=(rho,index,pixel)
    reductions={}
    for index,samples in bins.items():
        for pixel in set(samples):reductions[index,pixel]=rgb.reduction(samples,pixel)
    # This candidate is reported explicitly; selection is not an accepted API
    # contract. Black0/0 is ignored; row-major equal ratios retain first entry.
    seed=None;minimum=math.inf
    for y in range(top,bottom):
        for x in range(left,right):
            r,g,b,a=source[4*(y*width+x):4*(y*width+x)+4]
            if a==0 or g==0:continue
            ratio=r/g
            if ratio<minimum:minimum=ratio;seed=(x,y)
    seed_eligible=seed is not None and math.hypot((seed[0]-cx)/rx,(seed[1]-cy)/ry)<=2/3
    # Invert the native rounding intervals only as a diagnostic constraint.
    # This observed coefficient is NEVER fed back into a prediction.
    cone_bins={};cone_lower=-math.inf;cone_upper=math.inf
    for (x,y),(rho,index,pixel) in coords.items():
        if pixel[3]!=255:continue
        parts=reductions[index,pixel];z=max(0,pixel[0]-(pixel[1]+pixel[2])/2)
        mu=sum(max(0,p[0]-(p[1]+p[2])/2)for p in bins[index])/len(bins[index])
        m=max(0,pixel[0]-max(pixel[1:3]));h=(z-mu)/z if z>0 else 0;q=1-rho
        if not m or not z or q<=0 or 1-h<=0:continue
        r,g,b,_=pixel;offset=4*(y*width+x);rr,gg,bb,_=observed[offset:offset+4]
        low=max((r-rr-.5)*16/11,(gg-g-.5)*16/5,(bb-b-.5)*16/5)
        high=min((r-rr+.5)*16/11,(gg-g+.5)*16/5,(bb-b+.5)*16/5)
        if low<=parts['strength']+1:continue
        # Exclude the separately supplied candidate glint support.
        if seed_eligible and (x-seed[0])**2+(y-seed[1])**2<=m/5:continue
        lower=(low/m-h)/((1-h)*q*q);upper=(high/m-h)/((1-h)*q*q)
        row=cone_bins.setdefault(index,dict(count=0,lower=-math.inf,upper=math.inf))
        row['count']+=1;row['lower']=max(row['lower'],lower);row['upper']=min(row['upper'],upper)
        cone_lower=max(cone_lower,lower);cone_upper=min(cone_upper,upper)
    cone_constraint=dict(qualification='Inverted original RGB rounding constraints; no inferred value is used to predict pixels. Candidate glint support and angular-floor-dominated points are excluded.',
        interval=[cone_lower,cone_upper]if cone_bins else None,bins=cone_bins)
    hypotheses=[]
    for cone_factor in (1,3):
      for glint in (False,True):
        failures=[];max_delta=0;compared=0;outside_seed_fail=0;inside_seed_fail=0;nonopaque=0;histogram={}
        for y in range(height):
          for x in range(width):
            offset=4*(y*width+x);pixel=list(source[offset:offset+4]);predicted=pixel;strength=0
            if pixel[3]!=255:nonopaque+=1
            if (x,y)in coords:
                rho,index,_=coords[x,y];parts=reductions[index,tuple(pixel)]
                m=max(0,pixel[0]-max(pixel[1:3]));h=parts['linearExcess'];q=1-rho
                if signed_excess:
                    z=max(0,pixel[0]-(pixel[1]+pixel[2])/2);mu=sum(max(0,p[0]-(p[1]+p[2])/2)for p in bins[index])/len(bins[index])
                    h=(z-mu)/z if z>0 else 0
                radial=m*(h+(1-h)*cone_factor*q*q/4)
                circle=max(0,m-5*((x-seed[0])**2+(y-seed[1])**2))if glint and seed_eligible else 0
                strength=max(radial,parts['strength'],circle)
                predicted=rgb.corrected(pixel,strength);predicted[3]=pixel[3]
            actual=list(observed[offset:offset+4]);delta=max(abs(a-b)for a,b in zip(predicted,actual));max_delta=max(max_delta,delta);compared+=1
            histogram[str(delta)]=histogram.get(str(delta),0)+1
            if delta>1:
                in_circle=seed_eligible and (x-seed[0])**2+(y-seed[1])**2<=max(0,pixel[0]-max(pixel[1:3]))/5
                if in_circle:inside_seed_fail+=1
                else:outside_seed_fail+=1
                failures.append(dict(x=x,y=y,source=pixel,predicted=predicted,nativeFile=actual,strength=strength,maxByteDelta=delta))
        hypotheses.append(dict(coneFactor=cone_factor,includeCandidateGlint=glint,comparedPixelCount=compared,maxByteDelta=max_delta,pixelsExceedingOne=len(failures),failuresOutsideCandidateGlint=outside_seed_fail,failuresInsideCandidateGlint=inside_seed_fail,nonopaquePixelCount=nonopaque,byteDeltaHistogram=histogram,firstFailures=failures[:30]))
    return dict(name=name,sourceSHA256=digest(source),nativeFileSHA256={mode:digest(data)for mode,data in references},v1v2FileEqual=references[0][1]==references[1][1],dimensions=[width,height],initialROIOrigin=initial_center,centerPolicy=center_policy,centerIterations=center_iterations,suppliedROIOrigin=[cx,cy],suppliedROIRadii=[rx,ry],candidateSeed=seed,candidateSeedEligible=seed_eligible,inferredConeCoefficientConstraint=cone_constraint,qualification='ROI origin/ellipse plus minimum R/G and2/3 eligibility are explicit unaccepted geometry hypotheses. All source statistics are measured afresh; cone factors1 and3 are both reported without case-based selection.',hypotheses=hypotheses)


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--observation',choices=['replay-v1','replay'],default='replay-v1');parser.add_argument('--reduction',choices=['rgb-dispersion','mixture-mean'],default='rgb-dispersion');parser.add_argument('--geometry',choices=['ellipse','min-radius-circle'],default='ellipse');parser.add_argument('--signed-excess',action='store_true');parser.add_argument('--angle',choices=['atan2','endpoint-linear','endpoint-cubic','endpoint-quintic'],default='atan2');parser.add_argument('--center',choices=['roi','positive-centroid','positive-bounds','ellipse-positive-centroid','iterative-positive-centroid'],default='roi');parser.add_argument('output',type=Path);parser.add_argument('artifacts',type=Path,nargs='+');args=parser.parse_args()
    if args.reduction=='mixture-mean':
        global rgb
        mean_spec=importlib.util.spec_from_file_location('rgb_mean',Path(__file__).with_name('analyze-redeye-mean-extension.py'))
        rgb=importlib.util.module_from_spec(mean_spec);mean_spec.loader.exec_module(rgb)
    artifacts=[]
    for root in args.artifacts:
        generated=json.loads((root/'generate.json').read_text());replays={mode:json.loads((root/(mode+'.json')).read_text())for mode in ('replay','replay-v1')}
        items=([generated['baseline']]if 'baseline'in generated else[])+generated['cases']
        items=[item for item in items if item.get('family','redEyeCorrection')=='redEyeCorrection']
        artifacts.append(dict(path=str(root),generateSHA256=digest((root/'generate.json').read_bytes()),cases=[analyze_case(root,item,replays,args.geometry,args.signed_excess,args.center,args.angle,args.observation)for item in items]))
    report=dict(observationMode=args.observation,reduction=args.reduction,anglePolicy=args.angle,centerPolicy=args.center,geometry=args.geometry,signedExcess=args.signed_excess,qualification='Mathematical full-buffer diagnostic only, not application validation or accepted general detector. Every native oracle is original FILE output; no fixtures or sources are modified.',radialFormula='M*(signedExcess+(1-signedExcess)*coneFactor*Q^2/4)' if args.signed_excess else 'M*(positiveExcess+(1-positiveExcess)*coneFactor*Q^2/4)',composition='max(radialStrength,RGBDispersionAngularFloor,suppliedCandidateGlintStrength)',artifacts=artifacts)
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(report,indent=2)+'\n')
    for artifact in artifacts:
        print(artifact['path'])
        for case in artifact['cases']:
            if 'hypotheses'not in case:print(case['name'],case['skipped']);continue
            print(case['name'],[(h['coneFactor'],h['includeCandidateGlint'],h['pixelsExceedingOne'],h['maxByteDelta'],h['failuresOutsideCandidateGlint'])for h in case['hypotheses']])

if __name__=='__main__':main()
