#!/usr/bin/env python3
"""Validate native detector transport and expose RGB statistical constraints.

No fitted coefficients, application pixels, detector fallback or tolerance are
created here. Pure-red and alpha method differences are retained explicitly.
"""
import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import struct


def sha(data):
    return hashlib.sha256(data).hexdigest()


def strength_interval(source,observed):
    r,g,b,_=source;rr,gg,bb,_=observed
    return [max((r-rr-.5)*16/11,(gg-g-.5)*16/5,(bb-b-.5)*16/5),
            min((r-rr+.5)*16/11,(gg-g+.5)*16/5,(bb-b+.5)*16/5)]


def statistics(samples):
    n=len(samples)
    mean=[sum(pixel[k] for pixel in samples)/n for k in range(3)]
    covariance=[[sum((pixel[k]-mean[k])*(pixel[j]-mean[j]) for pixel in samples)/n for j in range(3)] for k in range(3)]
    result=dict(count=n,rgbMean=mean,rgbPopulationCovariance=covariance,
                rgbHistogram=[dict(rgba=list(pixel),count=count) for pixel,count in sorted(Counter(samples).items())])
    scores={
        'clampedRedMinusAverageGreenBlue':[max(0,p[0]-(p[1]+p[2])/2)/255 for p in samples],
        'signedRedMinusTwoGreen':[(p[0]-2*p[1])/255 for p in samples],
        'signedRedMinusGreenBlue':[(p[0]-p[1]-p[2])/255 for p in samples],
    }
    result['scoreMoments']={}
    for name,values in scores.items():
        mu=sum(values)/n
        result['scoreMoments'][name]=dict(mean=mu,populationVariance=sum((v-mu)**2 for v in values)/n,
                                         minimum=min(values),maximum=max(values),
                                         histogram=[dict(value=v,count=count) for v,count in sorted(Counter(values).items())])
    return result


def analyze(root):
    manifests={mode:json.loads((root/(mode+'.json')).read_text()) for mode in ('generate','direct-v1','replay','replay-v1')}
    rows=[];status_count=0
    for case in manifests['generate']['cases']:
        name=case['atlas'];width,height=case['sourceWidth'],case['sourceHeight']
        source=(root/('atlas-'+name+'.rgba')).read_bytes()
        requested=(root/('atlas-'+name+'-requested.rgba')).read_bytes()
        if len(source)!=4*width*height or len(requested)!=len(source):
            raise ValueError('source extent mismatch: '+name)
        observations=[]
        for mode,manifest in manifests.items():
            item=next(item for item in manifest['cases'] if item['atlas']==name)
            if mode in ('generate','direct-v1'):
                if mode=='generate':
                    for field in ('recordSetParametersStatus','recordCreateStatus','recordStatus'):
                        status_count+=1
                        if item[field]!=0:raise ValueError('native record failure: '+name+'/'+field)
                for key in ('direct','created'):
                    record=item[key]
                    for field in ('setParametersStatus','applyStatus'):
                        status_count+=1
                        if record[field]!=0:raise ValueError('native direct failure: '+name+'/'+mode+'/'+key+'/'+field)
                    data=(root/record['rgba']).read_bytes()
                    if len(data)!=4*width*height:raise ValueError('direct extent mismatch: '+name)
                    observations.append((mode+'/'+key,data))
            else:
                for field in ('bitmapLoadStatus','drawStatus'):
                    status_count+=1
                    if item[field]!=0:raise ValueError('native file failure: '+name+'/'+mode+'/'+field)
                if not item['expectedSize']:raise ValueError('native file dimension failure: '+name)
                for key,record in (('final',item),('intrinsic',item['intrinsic'])):
                    data=(root/record['rgba']).read_bytes()
                    if len(data)!=len(source):raise ValueError('file extent mismatch: '+name)
                    observations.append((mode+'/'+key,data))
        actual=observations[0][1]
        file_rgba=next(data for key,data in observations if key=='replay/final')
        row=dict(name=name,group=case['group'],sourceSHA256=sha(source),requestedSHA256=sha(requested),
            actualSourceEqualsRequested=source==requested,
            allEightObservationBuffersIdentical=all(data==actual for key,data in observations),
            observationHashes={key:sha(data) for key,data in observations},
            observationDifferences={key:dict(channelCount=sum(a!=b for a,b in zip(actual,data)),
                maximumAbsoluteDelta=max(abs(a-b)for a,b in zip(actual,data))) for key,data in observations},
            sourceDefinition=case['sourceDefinition'])
        definition=case['sourceDefinition'];background=bytes(definition['backgroundRGBA'])
        if width==height==32 and case['parameters']['areas']==[[0,0,32,32]] and not definition['foregroundRectangles'] and background[3]==255:
            bins={}
            for hole in definition['holes']:
                angle=math.degrees(math.atan2(hole[1]-15.5,hole[0]-15.5))%360
                bins[int(angle//6)]=[]
            for y in range(height):
                for x in range(width):
                    rho=math.hypot(x-15.5,y-15.5)/15.5
                    if rho>=1:continue
                    index=int((math.degrees(math.atan2(y-15.5,x-15.5))%360)//6)
                    if index not in bins:continue
                    offset=4*(width*y+x)
                    bins[index].append((x,y,rho,tuple(source[offset:offset+4]),tuple(file_rgba[offset:offset+4])))
            scalar=[]
            for index,points in bins.items():
                # Outer band avoids the independently measured supplied glint
                # circles. Exact original samples and intervals remain visible.
                outer=[p for p in points if p[2]>=.75 and bytes(p[3])==background and
                         all(math.hypot(p[0]-h[0],p[1]-h[1])>=8 for h in definition['holes'])]
                if not outer:continue
                # Some native radial components start in this outer band.
                # Preserve them separately instead of forcing one scalar to
                # explain different observed RGB tuples at different radii.
                least=min(outer,key=lambda p:(background[0]-p[4][0])+(p[4][1]-background[1])+(p[4][2]-background[2]))[4]
                plateau=[p for p in outer if p[4]==least]
                intervals=[strength_interval(point[3],point[4]) for point in plateau]
                stat=statistics([point[3] for point in points])
                lower=max(interval[0]for interval in intervals);upper=min(interval[1]for interval in intervals)
                stat.update(bin=index,plateauStrengthInterval=[lower,upper],constantStrengthCompatible=lower<=upper,
                    plateauRadiusRange=[min(p[2]for p in plateau),max(p[2]for p in plateau)],
                    repeatedPlateauAtDistinctRadii=len(plateau)>1 and max(p[2]for p in plateau)-min(p[2]for p in plateau)>=.02,
                    outerBandPixels=[dict(x=p[0],y=p[1],source=list(p[3]),nativeFileRGBA=list(p[4])) for p in outer],
                    plateauPixels=[dict(x=p[0],y=p[1],source=list(p[3]),nativeFileRGBA=list(p[4])) for p in plateau])
                scalar.append(stat)
            row['suppliedROIOriginStatisticalConstraints']=scalar
        rows.append(row)
    # This compares complete spatial scalar planes, not just low-order moments.
    # Both probes are opaque and have the same hole position; examine unchanged
    # source-red pixels beyond every observed local-circle radius as well.
    neutral_inputs=[];neutral_outputs=[];neutral_planes=[]
    for name in ('neutral-0','neutral-255'):
        source=(root/('atlas-'+name+'.rgba')).read_bytes()
        item=next(item for item in manifests['replay']['cases'] if item['atlas']==name)
        output=(root/item['rgba']).read_bytes()
        plane=b''.join(struct.pack('<H',max(0,2*source[i]-source[i+1]-source[i+2])) for i in range(0,len(source),4))
        neutral_inputs.append(source);neutral_outputs.append(output);neutral_planes.append(plane)
    outer_differences=[]
    for y in range(32):
        for x in range(32):
            i=4*(32*y+x)
            if math.hypot(x-15,y-15)<8 or neutral_inputs[0][i:i+4]!=neutral_inputs[1][i:i+4]:continue
            if neutral_outputs[0][i:i+4]!=neutral_outputs[1][i:i+4]:
                outer_differences.append(dict(x=x,y=y,blackGlintNativeRGBA=list(neutral_outputs[0][i:i+4]),whiteGlintNativeRGBA=list(neutral_outputs[1][i:i+4])))
    proof=dict(sourceNames=['neutral-0','neutral-255'],scalarPlane='max(0,2*R-G-B), unsigned16 little-endian row-major',
        scalarPlaneHashes=[sha(plane)for plane in neutral_planes],completeSpatialScalarPlanesIdentical=neutral_planes[0]==neutral_planes[1],
        unchangedSourcePixelsBeyondEightPixelGlintRadiusWithDifferentOutput=len(outer_differences),
        differingOuterPixels=outer_differences,
        consequence='The angular component cannot be a function solely of this scalar plane, including any order of its moments or spatial filters. Additional RGB/brightness information is necessary.')
    return dict(qualification='Native SDK/file transport and statistical constraints, not a general implementation. Supplied ROI center is used only for uniform-background hole probes. Pure-red and alpha method differences are retained, never replaced by direct buffers.',
                caseCount=len(rows),checkedZeroStatusFields=status_count,
                normalizedSourceNames=[row['name']for row in rows if not row['actualSourceEqualsRequested']],
                differingObservationNames=[row['name']for row in rows if not row['allEightObservationBuffersIdentical']],
                identicalScalarPlaneCounterexample=proof,cases=rows)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact',type=Path);parser.add_argument('output',type=Path)
    args=parser.parse_args();report=analyze(args.artifact)
    args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({key:report[key] for key in ('caseCount','checkedZeroStatusFields','normalizedSourceNames','differingObservationNames')}))
