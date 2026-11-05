#!/usr/bin/env python3
"""Fit independent transformed fill controls and retain stroke counterexamples.

Inputs are only the original Windows capture and QualityReference.cpp geometry.
No TurtleGit/helper output is used, and this program launches no renderer.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path, PureWindowsPath
import struct

W, H = 128, 96
WEDGE = ((4.125,38.25),(54.875,40.125),(8.375,78.875))


def f32(value):
    return struct.unpack('<f',struct.pack('<f',value))[0]


def inside(x,y,points):
    result=False
    for index,(ax,ay) in enumerate(points):
        bx,by=points[(index+1)%len(points)]
        if (ay>y)!=(by>y):
            determinant=(bx-ax)*(y-ay)-(x-ax)*(by-ay)
            if determinant>0 if by>ay else determinant<0:
                result=not result
    return result


def transform(points,matrix,round_result):
    a,b,c,d,tx,ty=matrix
    result=[(a*x+c*y+tx,b*x+d*y+ty) for x,y in points]
    return [(f32(x),f32(y)) for x,y in result] if round_result else result


def quantize(points,mode):
    if mode=='raw':
        return points
    fn={'floor16':math.floor,'nearest16':lambda v:math.floor(v+.5),'ceil16':math.ceil}[mode]
    return [(fn(x*16)/16,fn(y*16)/16) for x,y in points]


def compare(data,points,roi,aa,pixel_half):
    nx,ny=(8,8) if aa else (1,1)
    phase=.5 if pixel_half else 0
    delta=[]
    for y in range(roi[1],roi[3]):
        for x in range(roi[0],roi[2]):
            count=sum(inside(x+phase+(-.5+i/nx if aa else 0),
                             y+phase+(-.5+j/ny if aa else 0),points)
                      for j in range(ny) for i in range(nx))
            expected=(count*255+nx*ny//2)//(nx*ny)
            actual=data[(y*W+x)*4+3]
            if expected!=actual:
                delta.append({'xy':[x,y],'windowsAlpha':actual,'modelAlpha':expected})
    return {'comparedPixels':(roi[2]-roi[0])*(roi[3]-roi[1]),
            'mismatchedPixels':len(delta),'firstDifferences':delta[:12]}


def dominant_line(start,end,phase,mode):
    axis=0 if abs(end[0]-start[0])>=abs(end[1]-start[1]) else 1
    minor=1-axis
    if start[axis]>end[axis]:
        start,end=end,start
    first=math.ceil(start[axis]-phase-.5)
    last=math.floor(end[axis]-phase)
    slope=(end[minor]-start[minor])/(end[axis]-start[axis])
    base=start[minor]+(first+phase-start[axis])*slope-phase
    if mode=='startfloor16':
        base=math.floor(base*16)/16
    elif mode=='startnearest16':
        base=math.floor(base*16+.5)/16
    elif mode=='startceil16':
        base=math.ceil(base*16)/16
    points=set()
    for major in range(first,last+1):
        value=base+(major-first)*slope
        if mode=='eachfloor16':
            value=math.floor(value*16)/16
        elif mode=='minus16':
            value-=1/16
        sub=math.ceil(value-.5)
        points.add((major,sub) if axis==0 else (sub,major))
    return points


def compare_line(data,points,roi,exclude_ellipse):
    delta=[];count=0;unrelated=[]
    for y in range(roi[1],roi[3]):
        for x in range(roi[0],roi[2]):
            # The thin diagonal is separate from the ellipse. Excluding its
            # whole padded bounds removes unrelated positive-alpha pixels,
            # without excluding any candidate/observed black line point.
            if exclude_ellipse and 65<=x<90 and 54<=y<78:
                continue
            count+=1
            pixel=tuple(data[(y*W+x)*4:(y*W+x)*4+4])
            if pixel[3] and pixel[:3]!=(0,0,0):
                unrelated.append({'xy':[x,y],'rgba':pixel})
            expected=255 if (x,y) in points else 0
            if expected!=pixel[3]:
                delta.append({'xy':[x,y],'windowsAlpha':pixel[3],'modelAlpha':expected})
    return {'comparedPixels':count,'mismatchedPixels':len(delta),
            'firstDifferences':delta[:12],'unrelatedColorPixels':unrelated[:12]}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('captures',type=Path)
    parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    folder=args.captures
    manifest=json.loads((folder/'quality-observations.json').read_text())
    if manifest['completedCaseCount']!=53 or len(manifest['cases'])!=53:
        raise SystemExit('Original independent53-case capture incomplete')
    hashes={PureWindowsPath(row['Path']).name:row['Hash'].lower()
            for row in json.loads((folder/'sha256.json').read_text())}
    inputs={}
    ordinary_names=tuple(f'ordinary-s{s}-p{p}' for s in (0,1,3) for p in (0,1,2,3,4))
    for name in ('save-restore','container','rectangle-container','affine-transform')+ordinary_names:
        file=name+'-natural.rgba';data=(folder/file).read_bytes()
        if len(data)!=W*H*4 or hashlib.sha256(data).hexdigest()!=hashes[file]:
            raise SystemExit('Independent capture identity mismatch: '+file)
        inputs[name]=data

    scale=f32(.45)
    cases=[]
    for name in ('save-restore','container','rectangle-container'):
        cases.append((name,'first-miniature',(scale,0,0,scale,0,0),(0,15,28,39),False))
        cases.append((name,'restored-miniature',(scale,0,0,scale,12,50),(12,65,40,89),False))
    cases.append(('affine-transform','affine-wedge',(.75,.125,f32(-.1),.75,18.25,4.5),(14,33,58,67),True))
    observations=[]
    for name,role,matrix,roi,half in cases:
        entry={'name':name,'role':role,'matrix':matrix,'roiXYExclusiveUpper':roi,
               'smoothing':'8x8','pixelOffset':'Half' if half else 'None','models':[]}
        for round_result in (False,True):
            points=transform(WEDGE,matrix,round_result)
            for mode in ('raw','floor16','nearest16','ceil16'):
                device=quantize(points,mode)
                entry['models'].append({'roundTransformedResultsToFloat32':round_result,
                    'quantization':mode,'deviceVertices':device,
                    **compare(inputs[name],device,roi,True,half)})
        observations.append(entry)

    # Independently formed analytic flat-cap stroke outline. Do not confuse a
    # successful fill-vertex rule with GDI+'s special aliased thin-line rasterizer.
    start,end=(112.25,18.125),(123.75,30.625)
    dx,dy=end[0]-start[0],end[1]-start[1]
    length=math.hypot(dx,dy);nx,ny=-dy/length*.5,dx/length*.5
    quad=((start[0]+nx,start[1]+ny),(end[0]+nx,end[1]+ny),
          (end[0]-nx,end[1]-ny),(start[0]-nx,start[1]-ny))
    stroke_counterexamples=[]
    for name,matrix,roi in (
        ('container',(1,0,0,1,0,0),(111,16,126,33)),
        ('rectangle-container',(.59375,0,0,.5,48,0),(113,8,124,17))):
        points=transform(quad,matrix,False)
        entry={'name':name,'roiXYExclusiveUpper':roi,'analyticFlatCapDeviceQuad':points,'models':[]}
        for mode in ('raw','floor16','nearest16','ceil16'):
            entry['models'].append({'quantization':mode,
                **compare(inputs[name],quantize(points,mode),roi,False,False)})
        entry['observedInk']=[{'xy':[x,y],'rgba':list(inputs[name][(y*W+x)*4:(y*W+x)*4+4])}
            for y in range(roi[1],roi[3]) for x in range(roi[0],roi[2])
            if inputs[name][(y*W+x)*4+3]]
        stroke_counterexamples.append(entry)

    dda=[]
    modes=('raw','startfloor16','startnearest16','startceil16','eachfloor16','minus16')
    verticals=tuple(((x,6),(x,28)) for x in (8,16.25,24.5,32.75))
    diagonal=(((64.25,38.125),(118.875,68.625)),)
    line_cases=[]
    for smoothing in (0,1,3):
        for offset in (0,1,2,3,4):
            name=f'ordinary-s{smoothing}-p{offset}'
            line_cases.append((name,'four-verticals',verticals,(4,4,39,32),offset in (2,4),False))
            line_cases.append((name,'thin-diagonal',diagonal,(62,36,121,71),offset in (2,4),True))
    line_cases.extend((
        ('container','entry-marker',(((112.25,18.125),(123.75,30.625)),),(111,16,126,33),False,False),
        ('rectangle-container','entry-marker',(((114.6484375,9.0625),(121.4765625,15.3125)),),(113,8,124,17),False,False)))
    for name,role,segments,roi,half,exclude in line_cases:
        entry={'name':name,'role':role,'pixelOffsetHalf':half,'roiXYExclusiveUpper':roi,'models':[]}
        for mode in modes:
            points=set()
            for start,end in segments:
                points.update(dominant_line(start,end,.5 if half else 0,mode))
            entry['models'].append({'interceptModel':mode,
                **compare_line(inputs[name],points,roi,exclude)})
        dda.append(entry)

    report={'schema':1,'successfulWindowsRun':41938727574,
        'preservedFailedCompileRun':41938313535,'originalCapturedCaseCount':53,
        'source':'Independent Windows natural replay pixels; no TurtleGit rendering expected data.',
        'inputRGBAHashes':{name+'-natural.rgba':hashes[name+'-natural.rgba'] for name in inputs},
        'fillRule':'Transform vertices to device coordinates, ceil each coordinate to1/16, then apply the calibrated anchored8x8 sample grid and half-open polygon inclusion. Float32-result rounding does not alter these observed fits.',
        'observations':observations,'aliasedThinStrokeCounterexamples':stroke_counterexamples,
        'aliasedThinLineDDA':dda,
        'noneOffsetLineRule':'Dominantfirst=ceil(minMajor-.5),last=floor(maxMajor). Projectminor once atfirst, floor that intercept to1/16, then minor=ceil(base+(major-first)*slope-.5). All9None-alias frames match the4verticals+thin-diagonal ROIs, as do both container markers. Rounding everyminor or addingconstant-1/16 bias does not fit the thin diagonal.',
        'halfOffsetLineLimit':'The simple coordinate-shifted version is not a full Half profile: it adds3wrong startpixels to the4vertical control and may alter diagonal minor selection. Those counterexamples remain explicit.',
        'limits':'The exact transformed fill fits do not establish quantization for curves, geometric pen outlines, joins/caps or arbitrary GDI+ paths. Aliased thin-line markers contradict a universal ceil16 stroke-outline rule. The observed DDA fits support only the bounded straight flat1px None-offset profile, not arbitrary line orientation, joins, dash/cap or Half rules.'}
    text=json.dumps(report,indent=2)+'\n'
    if args.output:
        args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(text)
    else:
        print(text,end='')


if __name__=='__main__':
    main()
