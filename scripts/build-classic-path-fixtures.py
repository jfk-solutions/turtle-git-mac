#!/usr/bin/env python3
"""Author bounded EMF classic path controls from the normative wire records.
No renderer output or Windows-derived expected pixels are generated.
"""
import argparse
import hashlib
import json
import math
from fractions import Fraction
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parent.parent
DEST = ROOT/'Tests/TurtleGitCoreTests/Fixtures/Metafile/ClassicPaths'
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--check', action='store_true')
args = p.parse_args()
word=lambda *n:struct.pack('<'+'I'*len(n),*(v&0xffffffff for v in n))
long=lambda *n:struct.pack('<'+'i'*len(n),*n)
short=lambda *n:struct.pack('<'+'h'*len(n),*n)
def record(kind, data=b''):
    data += b'\0'*(-len(data)%4)
    return word(kind, len(data)+8)+data

def pen(handle=1, width=2, color=0xff, style=0):
    return record(38,word(handle,style)+long(width,0)+word(color))
def extended(handle=1, width=8, color=0xff, style=0x10000, entries=()):
    return record(95,word(handle,0,0,0,0,style,width,0,color,0,len(entries),*entries))
def brush(handle=2, color=0xff0000):return record(39,word(handle,0,color,0))
def select(handle):return record(37,word(handle))
def poly(points, types, compact=True):
    assert len(points)==len(types)
    coords=b''.join((short if compact else long)(*point) for point in points)
    return record(92 if compact else 56,long(0,0,64,64)+word(len(points))+coords+bytes(types))
def line(x,y):return record(54,long(x,y))
def move(x,y):return record(27,long(x,y))
def world(a=1,b=0,c=0,d=1,x=0,y=0):return record(35,struct.pack('<6f',a,b,c,d,x,y))
def rectangle(l=0,t=0,r=64,b=64):return record(43,long(l,t,r,b))
BEGIN,END,CLOSE,FLATTEN,WIDEN,ABORT=[record(v) for v in [59,60,61,65,66,68]]
FILL,STROKE,BOTH=[record(v,long(0,0,64,64))for v in [62,64,63]]
CLIP=record(67,word(5))
PREFIX=[record(17,word(1)),select(0x80000000),select(0x80000008),rectangle(),pen(handle=7),select(7)]
RED_PREFIX=[brush(3,0xff),select(3),rectangle(2,2,8,8)]
HEADER=(ROOT/'Tests/TurtleGitCoreTests/Fixtures/Metafile/classic-extpen-dash.emf').read_bytes()[:88]
def emf(records):
    records=[*records,record(14,word(0,0,20))]
    header=bytearray(HEADER);struct.pack_into('<II',header,48,88+sum(map(len,records)),len(records)+1)
    return bytes(header)+b''.join(records)
fixtures={}
pairs=[]
def add(name, records, **metadata):
    filename=name+'.emf';fixtures[filename]=(emf(records),metadata);return filename
def pair(name, subject, control, **metadata):
    a=add(name,subject,**metadata);b=add(name+'-control',control,role='independent record control')
    pairs.append(dict(subject=a,control=b));return a

points=[(8,40),(16,8),(48,8),(56,40),(56,48),(8,48)]
types=[6,4,4,4,2,3]
explicit=[BEGIN,move(8,40),record(5,long(0,0,64,64)+word(3)+long(16,8,48,8,56,40)),line(56,48),line(8,48),CLOSE,END,STROKE]
for compact in [True,False]:
    pair('polydraw'+('16'if compact else'32')+'-cubic',PREFIX+[BEGIN,poly(points,types,compact),END,STROKE],PREFIX+explicit,role='typed cubic and explicit close')
    disjoint=[(8,12),(24,12),(24,24),(8,24),(40,40),(56,40),(56,52)]
    disjoint_types=[6,2,2,3,6,2,2]
    disjoint_control=[BEGIN,move(8,12),line(24,12),line(24,24),line(8,24),CLOSE,move(40,40),line(56,40),line(56,52),END,STROKE]
    pair('polydraw'+('16'if compact else'32')+'-figures',PREFIX+[BEGIN,poly(disjoint,disjoint_types,compact),END,STROKE],PREFIX+disjoint_control,role='multiple figures and close flag1')
    pair('polydraw'+('16'if compact else'32')+'-current-position',PREFIX+[move(8,40),poly([(24,16),(40,16),(56,40)],[4,4,4],compact),line(56,56)],PREFIX+[move(8,40),record(5,long(0,0,64,64)+word(3)+long(24,16,40,16,56,40)),line(56,56)],role='implicit current position and subsequent LineTo')
    pair('polydraw'+('16'if compact else'32')+'-close-current-position',PREFIX+[BEGIN,poly([(8,12),(24,12),(24,24)],[6,2,3],compact),line(8,40),END,STROKE],PREFIX+[BEGIN,move(8,12),line(24,12),line(24,24),CLOSE,move(8,12),line(8,40),END,STROKE],role='closing line returns current position to figure start')

curve=[BEGIN,move(8,40),record(5,long(0,0,64,64)+word(3)+long(16,8,48,8,56,40)),END]
# Independent Bernstein polynomial authoring, not returned FlattenPath points.
# N=256 and scale=2^21 make every sample an exact integer POINTL operand.
n=256;scale=1<<21
samples=[((8*n**3+24*i*n*n+72*i*i*n-48*i**3)//8,(40*n*n-96*i*n+96*i*i)*32)for i in range(1,n+1)]
bernstein=[world(a=1/scale,d=1/scale),BEGIN,move(8*scale,40*scale),record(6,long(0,0,64,64)+word(n)+b''.join(long(x,y)for x,y in samples)),END,world(),select(7)]
add('flatten-original-cubic',PREFIX+curve+[STROKE],role='original native cubic raster retained separately; not assumed pixel-identical to flattened line coverage')
add('flatten-rounded-bernstein',PREFIX+bernstein+[STROKE],role='additional valid EMF wire; legacy SvgContext rounds device vertices to two decimals, not an exact geometry oracle')
# Independent global interpolation-error bound: ||B''|| is bounded by the
# larger endpoint second derivative (its vector is affine). M/(8*N*N) bounds
# each uniform chord error. Choose the first power of two satisfying tolerance,
# without reading renderer output, its point count or its adaptive subdivision.
authored_cubic=[(8,40),(16,8),(48,8),(56,40)]
second_derivatives=[tuple(6*(authored_cubic[i+2][axis]-2*authored_cubic[i+1][axis]+authored_cubic[i][axis])for axis in range(2))for i in range(2)]
maximum_second_derivative=max(math.hypot(*value)for value in second_derivatives)
flatten_tolerance=Fraction(1,256)
required=math.ceil(math.sqrt(maximum_second_derivative/(8*float(flatten_tolerance))))
reference_count=1
while reference_count<required:reference_count*=2
def bernstein_reference(following=False,count=reference_count):
    points=[]
    for i in range(1,count+1):
        t=Fraction(i,count)
        points.append((8+24*t+72*t*t-48*t*t*t,40-96*t+96*t*t))
    path='M 8 40'+''.join(' L '+repr(float(x))+' '+repr(float(y))for x,y in points)
    attributes=' fill="none" stroke="#ff0000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"'
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="65" height="65" viewBox="0 0 65 65">'+
            '<rect x="0" y="0" width="65" height="65" fill="#ffffff" stroke="none"/>'+
            '<path d="'+path+'"'+attributes+'/>'+
            ('<path d="M 56 40 L 56 56"'+attributes+'/>'if following else'')+'</svg>\n').encode()
fixtures['flatten-bernstein-256.svg']=(bernstein_reference(count=256),dict(role='retained independently authored oversampled control; diagnostic positive, not the full-frame oracle',format='svg'))
for name,following in [('flatten-cubic-stroke',False),('flatten-following-position',True)]:
    subject=add(name,PREFIX+curve+[FLATTEN,STROKE]+([line(56,56)]if following else[]),role='bounded line-only replacement and logical current position',tolerance=2)
    control=name+'-control.svg'
    fixtures[control]=(bernstein_reference(following),dict(role='independent exact authored Bernstein rational SVG, not returned renderer geometry',format='svg'))
    pairs.append(dict(subject=subject,control=control))
pair('flatten-no-early-ink',PREFIX+curve+[FLATTEN,ABORT],PREFIX,role='replacement alone never paints')
pair('flatten-active-save-restore',PREFIX+[BEGIN,move(8,12),line(24,12),record(33),line(56,56),record(34,long(-1)),line(24,40),END,FLATTEN,STROKE],PREFIX+[BEGIN,move(8,12),line(24,12),line(24,40),END,STROKE],role='open path and current position belong to SaveDC')
pair('flatten-completed-save-restore',PREFIX+curve+[record(33),ABORT,BEGIN,move(8,8),line(56,8),END,record(34,long(-1)),FLATTEN,STROKE],PREFIX+curve+[FLATTEN,STROKE],role='completed path survives replacement and RestoreDC')

for name,style,entries in [('round',0x10000,()),('flat',0x10200,()),('square',0x10100,()),('miter',0x12200,()),('bevel',0x11200,()),('dash',0x10207,(8,4))]:
    setup=PREFIX+[extended(width=8,color=0xff0000,style=style,entries=entries),select(1),brush(color=0xff0000),select(2)]
    route=[BEGIN,move(12,24),line(36,24),line(48,40),END]
    pair('widen-'+name+'-fill',setup+route+[WIDEN,FILL],setup+route+[STROKE],role='current selected geometric pen becomes fill area',tolerance=2)
setup=PREFIX+[extended(width=2,style=0x10200),select(1),BEGIN,move(12,24),line(52,24),END,extended(handle=4,width=10,style=0x10200),select(4),brush(color=0xff0000),select(2)]
add('widen-current-pen',setup+[WIDEN,FILL],role='operation uses new selected pen; blue fill, not red pen color')
add('widen-normal-wide',PREFIX+[pen(width=8),select(1),brush(color=0xff0000),select(2),BEGIN,move(12,24),line(52,24),END,WIDEN,FILL],role='CreatePen width above1')
clip_setup=PREFIX+[extended(width=8,style=0x10200),select(1),BEGIN,move(12,24),line(52,24),END,WIDEN,CLIP,brush(color=0x00ff00),select(2),select(0x80000008)]
add('widen-clip',clip_setup+[rectangle()],role='widened geometry consumed by SelectClipPath')
pair('widen-no-early-ink',PREFIX+curve+[extended(width=8),select(1),WIDEN,ABORT],PREFIX,role='widen alone never paints')
pair('widen-device-capture',PREFIX+[world(a=2,x=8),BEGIN,move(8,16),line(24,16),END,world(),extended(width=8,style=0x10200),select(1),brush(color=0xff0000),select(2),WIDEN,FILL],PREFIX+[BEGIN,move(24,16),line(56,16),END,extended(width=8,style=0x10200),select(1),brush(color=0xff0000),select(2),WIDEN,FILL],role='captured device geometry survives later world change')
add('widen-cubic-flatten-repeat',PREFIX+curve+[extended(width=6,style=0x10200),select(1),WIDEN,FLATTEN,FLATTEN,brush(color=0xff0000),select(2),FILL],role='cubic widening then repeated replacement')

# Native GDI accepts these ordinary/stock/null pen geometries. Controls use
# separate supported record constructions, never output generated by renderer.
def fill_route(setup, route=None):
    return PREFIX+setup+[brush(color=0xff0000),select(2)]+(route or [BEGIN,move(8,16),line(48,16),END])+[WIDEN,FILL]
round_one=[extended(width=1),select(1)]
flat_one=[extended(width=1,style=0x10200),select(1)]
implicit_setup=[record(17,word(1)),brush(color=0xff0000),select(2)]
implicit_route=[BEGIN,move(8,16),line(48,16),END,WIDEN,FILL]
pair('widen-default-pen',implicit_setup+implicit_route,implicit_setup+[select(0x80000007)]+implicit_route,role='unselected native DC pen is implicit stock BLACK_PEN without mutating selection')
pair('widen-normal-thin',fill_route([pen(width=1),select(1)]),fill_route(round_one),role='native-success CreatePen width1')
pair('widen-normal-zero',fill_route([pen(width=0),select(1)]),fill_route(flat_one),role='native-success CreatePen zero device hairline')
pair('widen-stock',fill_route([select(0x80000007)]),fill_route(flat_one),role='native-success stock BLACK_PEN device hairline')
pair('widen-null',fill_route([pen(width=2,style=5),select(1)]),fill_route(flat_one),role='native-success null pen still supplies solid device geometry')
pair('widen-normal-wide-dash-solid',fill_route([pen(width=8,style=1),select(1)]),fill_route([pen(width=8),select(1)]),role='CreatePen width above1 normalizes built-in dash to solid')
pair('widen-shrunk-minimum',fill_route([world(a=.25,d=.25),pen(width=2),select(1)]),fill_route(round_one,[BEGIN,move(2,4),line(12,4),END]),role='shrunk classic nib retains minimum one device pixel')
for name,transform,width in [('enlarged',world(a=3,d=3),1),('anisotropic',world(a=3,d=.25),2),('sheared',world(a=1,b=1.5,c=.25,d=1),1)]:
    add('widen-normal-'+name,fill_route([transform,pen(width=width),select(1)]),role='native-success transformed ordinary nib and minimum device coverage')

for compact in [True,False]:
    prefix='refused-polydraw'+('16'if compact else'32')+'-'
    for suffix,pts,ts in [('unknown-type',[(8,8)],[8]),('zero-type',[(8,8)],[0]),('close-move',[(8,8)],[7]),('short-cubic',[(8,8),(16,16)],[4,4]),('mixed-cubic',[(8,8),(16,16),(24,8)],[4,2,4]),('first-close',[(8,8),(16,16),(24,8)],[5,4,4]),('second-close',[(8,8),(16,16),(24,8)],[4,5,4])]:
        add(prefix+suffix,PREFIX+RED_PREFIX+[BEGIN,poly(pts,ts,compact),END,STROKE],refused=True)
    raw=poly([(8,8),(16,16)],[6,2],compact)
    add(prefix+'truncated',PREFIX+RED_PREFIX+[BEGIN,raw[:-4],END,STROKE],refused=True,framing=True)
for name,records in [('nested-begin',[BEGIN,BEGIN]),('end-without-begin',[END]),('flatten-idle',[FLATTEN]),('widen-idle',[WIDEN]),('flatten-active',[BEGIN,FLATTEN]),('stroke-active',[BEGIN,STROKE]),('clip-active',[BEGIN,CLIP]),('flatten-body',curve+[record(65,word(0))]),('widen-body',curve+[record(66,word(0))]),('widen-cosmetic',curve+[extended(width=1,style=0),select(1),WIDEN])]:
    add('refused-'+name,PREFIX+RED_PREFIX+records,refused=True)

add('refused-selected-path-text-budget',PREFIX+RED_PREFIX+[BEGIN,move(0,0),record(6,long(0,0,64,64)+word(110000)+long(999999999,-999999999)*110000),END,FILL],refused=True,role='legacy path construction exceeds selected text budget before any consumer ink')
add('refused-path-scan-budget',PREFIX+RED_PREFIX+[BEGIN]+[poly([(8,8)],[2])]*4000+[END,STROKE],refused=True,role='repeated small PolyDraw cannot cause unbounded cumulative joined-path scanning')

manifest=dict(schema=1,source='Normative manually authored EMF records and two independent exact Bernstein SVG controls; no renderer-generated or Windows pixel expectations',specifications=['https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/01b63e3f-19d6-437c-8fc6-2758884bc08d','https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/b930b989-30ec-4954-a889-1dc60ce0b689','https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-widenpath'],pairs=pairs,files=[],flattenReference=dict(method='uniform chord error <= sup norm of second derivative / (8*N^2); next power of two',maximumSecondDerivative=maximum_second_derivative,tolerance=float(flatten_tolerance),subdivisions=reference_count))
for name,(data,meta)in sorted(fixtures.items()):manifest['files'].append(dict(file=name,sha256=hashlib.sha256(data).hexdigest(),bytes=len(data),**meta))
outputs={name:data for name,(data,_)in fixtures.items()};outputs['manifest.json']=(json.dumps(manifest,indent=2,sort_keys=True)+'\n').encode()
if args.check:
    differing=[name for name,data in outputs.items() if not(DEST/name).is_file()or(DEST/name).read_bytes()!=data]
    if differing:raise SystemExit('Classic path fixture mismatch: '+', '.join(differing))
else:
    DEST.mkdir(parents=True,exist_ok=True)
    for name,data in outputs.items():
        target=DEST/name
        if target.exists()and target.read_bytes()!=data:raise SystemExit('Refusing to overwrite changed fixture: '+str(target))
        target.write_bytes(data)
print('Classic path controls:',len(fixtures),'files,',len(pairs),'paired contracts')
