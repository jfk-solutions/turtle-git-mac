#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Original EMF+ interpolation controls; no expected image uses our renderer.

Wire structures follow MS-EMF/MS-EMFPLUS. All sample coordinates in the opaque
axis controls map to exact binary fractions, independently of a rasterizer's
floating-point accumulation. Native Windows phase observations are recorded
separately from this deterministic authoring program.
"""
import hashlib
import json
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parent
U = lambda *v: struct.pack('<'+'I'*len(v), *v)
I = lambda *v: struct.pack('<'+'i'*len(v), *v)
F = lambda *v: struct.pack('<'+'f'*len(v), *v)
H = lambda *v: struct.pack('<'+'H'*len(v), *v)
def pad(b): return b + bytes(-len(b) % 4)
def rec(t, b=b''): return U(t, len(pad(b))+8)+pad(b)
def ep(t, b=b'', flags=0): return H(t, flags)+U(12+len(pad(b)), len(b))+pad(b)
def scene(records):
    stream=ep(0x4001,U(0xdbc01002,0,96,96),1)+b''.join(records)+ep(0x4002)
    records=[rec(70,U(len(stream)+4)+b'EMF+'+stream),rec(14,U(0,0,20))]
    header=U(1,88)+I(0,0,96,64)+I(0,0,2540,1693)+U(0x464d4520,0x10000,88+sum(map(len,records)),len(records)+1)+H(16,0)+U(0,0,0)+I(960,960,254,254)
    assert len(header)==88
    return header+b''.join(records)
def chunk(t,b): return struct.pack('>I',len(b))+t+b+struct.pack('>I',zlib.crc32(t+b)&0xffffffff)
OPAQUE=[[255,0,0,255],[0,255,0,255],[0,0,255,255],[255,255,255,255]]
ALPHA=[[255,0,0,128],[0,255,0,255],[0,0,255,0],[255,255,255,64]]
def image(atlas):
    rgba=bytes(sum(atlas,[]))
    png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',2,2,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(b'\0'+rgba[:8]+b'\0'+rgba[8:]))+chunk(b'IEND',b'')
    return ep(0x4008,U(0xdbc01002,1)+I(0,0,0)+U(0,1)+png,0x500)
def attributes(wrap=4,clamp=0): return ep(0x4008,U(0xdbc01002,0,wrap,clamp,0,0),0x803)
def mode(m): return ep(0x4021,flags=m)
def draw(dest=(8,8,32,32),source=(0,0,2,2),attr=0xffffffff):
    return ep(0x401a,U(attr,2)+F(*source)+F(*dest))
def points(dest=(8,8,40,16,16,40),source=(0,0,2,2)):
    return ep(0x401b,U(0xffffffff,2)+F(*source)+U(3)+F(*dest))
def fill(color,rect=(0,0,96,64)):
    return ep(0x400a,U(color,1)+F(*rect),0x8000)

cases=[]
def positive(name,records,description,**metadata):
    b=scene(records);(ROOT/name).write_bytes(b)
    cases.append(dict(file=name,sourceSHA256=hashlib.sha256(b).hexdigest(),width=97,height=65,description=description,**metadata))
for value,name in [(None,'implicit-default'),(0,'bilinear-default'),(1,'bilinear-low'),(3,'bilinear'),(5,'nearest')]:
    positive(name+'.emf',[image(OPAQUE)]+([] if value is None else [mode(value)])+[draw()],
             'Opaque red/green; blue/white 2x2 checkerboard, source(0,0,2,2), destination(8,8,32,32).',mode=value,atlas=OPAQUE)
positive('nearest-reserved-flags.emf',[image(OPAQUE),mode(0xff05),draw()],
         'Reserved high interpolation flags do not change the low-byte nearest kernel.',mode=5,atlas=OPAQUE)
for value,name in [(3,'bilinear'),(5,'nearest')]:
    positive('alpha-'+name+'.emf',[image(ALPHA),mode(value),draw()],
             'Original straight RGBA with partial and zero alpha; no implicit background.',mode=value,atlas=ALPHA)
    positive('affine-'+name+'.emf',[image(OPAQUE),mode(value),points()],
             'Affine parallelogram with source basis(16,4),(4,16) and origin(8,8).',mode=value,atlas=OPAQUE)
    positive('crop-'+name+'.emf',[image(OPAQUE),mode(value),draw((8,8,16,32),(.5,0,1,2))],
             'Fractional source rectangle(.5,0,1,2), with actual original-image neighbors.',mode=value,atlas=OPAQUE)
    positive('clamp-'+name+'.emf',[image(OPAQUE),attributes(4,0xffff00ff),mode(value),draw((8,8,32,32),(-1,-1,4,4),3)],
             'Opaque magenta clamp outside original bitmap, enlarged negative source rectangle.',mode=value,atlas=OPAQUE)
    positive('wrap-'+name+'.emf',[image(OPAQUE),attributes(3),mode(value),draw((8,8,48,48),(-2,-2,6,6),3)],
             'TileFlipXY repeats original source through negative and positive coordinates.',mode=value,atlas=OPAQUE)
    positive('source-copy-'+name+'.emf',[fill(0xff808080),image(ALPHA),mode(value),ep(0x4023,flags=1),draw()],
             'SourceCopy replaces prior gray paint including transparent covered pixels.',mode=value,atlas=ALPHA)
    positive('clip-'+name+'.emf',[image(OPAQUE),mode(value),ep(0x4032,F(12,12,8,8)),draw()],
             'Device clip must restrict the sampled image rather than only its original SVG bounds.',mode=value,atlas=OPAQUE)
positive('saved-container-state.emf',[
    image(OPAQUE),mode(5),ep(0x4025,U(17)),mode(3),draw((8,8,8,8)),
    ep(0x4026,U(17)),draw((32,8,8,8)),ep(0x4028,U(19)),draw((56,8,8,8)),
    ep(0x4029,U(19)),draw((80,8,8,8))],
    'Four panels: changed bilinear; restored nearest; container default bilinear; restored parent nearest.',atlas=OPAQUE,panelModes=[3,5,0,5])
refused=[]
for value in [2,4,6,7,8,255]:
    name='refused-mode-'+str(value)+'.emf';(ROOT/name).write_bytes(scene([image(OPAQUE),mode(value),draw()]));refused.append(name)
for name,record in [('body',ep(0x4021,U(0),5)),('late-body',ep(0x4021,U(0),5))]:
    file='refused-'+name+'.emf';(ROOT/file).write_bytes(scene([image(OPAQUE)]+([draw()] if name=='late-body' else [])+[record,draw()]));refused.append(file)
# Sample expectations are intentionally authored separately after observing the
# Windows integer/half-pixel phase; this script does not produce expected RGBA.
definition=dict(cases=cases,refused=refused,nativeRoles=dict(nearest='nearest.emf',bilinear='bilinear.emf',state='saved-container-state.emf',affine='affine-nearest.emf'))
(ROOT/'wire-definition.json').write_text(json.dumps(definition,indent=2)+'\n')
print('Authored',len(cases),'positive and',len(refused),'refusal records.')
