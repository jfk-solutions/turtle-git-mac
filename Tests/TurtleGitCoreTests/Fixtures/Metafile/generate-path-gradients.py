#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Original MS-EMFPLUS path-gradient wire corpus; no renderer/test invocation.

Every ordinary polygon uses an explicit closed line EmfPlusPath. The flag-zero
BoundaryPointData case remains separate: Windows playback proves line-polygon
semantics despite the MS-EMFPLUS prose describing a closed cardinal spline.
Existing fixtures are not read or rewritten. Windows sample expectations are
recorded independently by the reference assay, not computed here.
"""
import json
import math
from pathlib import Path
import struct
P=Path(__file__).parent
U=lambda *v:struct.pack('<'+'I'*len(v),*v)
I=lambda *v:struct.pack('<'+'i'*len(v),*v)
H=lambda *v:struct.pack('<'+'H'*len(v),*v)
F=lambda *v:struct.pack('<'+'f'*len(v),*v)
V=0xdbc01002

def pad(b):return b+b'\0'*(-len(b)%4)
def record(t,b):return U(t,len(pad(b))+8)+pad(b)
def ep(t,b=b'',flags=0):return H(t,flags)+U(12+len(pad(b)),len(b))+pad(b)
def emf(records,width=64,height=64):
 stream=ep(0x4001,U(V,1,96,96),0)+ep(0x4030,F(1),2)+b''.join(records)+ep(0x4002)
 rs=[record(70,U(len(stream)+4)+b'EMF+'+stream),record(14,U(0,0,20))]
 header=U(1,88)+I(0,0,width-1,height-1)+I(0,0,round(width*2540/96),round(height*2540/96))+U(0x464d4520,0x10000,88+sum(map(len,rs)),len(rs)+1)+H(16,0)+U(0,0,0)+I(960,960,254,254)
 return header+b''.join(rs)
def path(points,types=None):
 types=types or [0]+[1]*(len(points)-2)+[0x81]
 return U(V,len(points),0)+F(*(v for p in points for v in p))+pad(bytes(types))
SQUARE=[(8.5,8.5),(56.5,8.5),(56.5,56.5),(8.5,56.5)]
TRIANGLE=[(8.5,8.5),(56.5,8.5),(32.5,56.5)]
CONCAVE=[(8.5,8.5),(56.5,8.5),(56.5,24.5),(24.5,24.5),(24.5,56.5),(8.5,56.5)]
RED=0xffff0000;BLUE=0xff0000ff;GREEN=0xff00ff00;WHITE=0xffffffff

def brush(points=SQUARE,center=(32.5,32.5),colors=(BLUE,),center_color=RED,transform=None,focus=None,gamma=False,wrap=4,stops=None,blend=None,boundary_path=True,raw_path=None):
 flags=(1 if boundary_path else 0)|(2 if transform else 0)|(4 if stops else 0)|(8 if blend else 0)|(0x40 if focus is not None else 0)|(0x80 if gamma else 0)
 boundary=path(points) if raw_path is None else raw_path
 b=U(V,3,flags,wrap,center_color)+F(*center)+U(len(colors),*colors)
 b+=(U(len(boundary))+boundary) if boundary_path else U(len(points))+F(*(v for p in points for v in p))
 if transform:b+=F(*transform)
 if stops:b+=U(len(stops))+F(*(p for p,c in stops))+U(*(c for p,c in stops))
 if blend:b+=U(len(blend))+F(*(p for p,f in blend))+F(*(f for p,f in blend))
 if focus is not None:b+=U(2)+F(*focus)
 return b
manifest=[]
def emit(name,b=None,draw=None,extra=(),prefix=(),classification='supported-candidate'):
 b=brush() if b is None else b
 rs=[ep(0x4009,U(WHITE)),*prefix,ep(0x4008,b,0x100),*(draw or [ep(0x400A,U(0,1)+F(0,0,64,64))]),*extra]
 filename='path-gradient-'+name+'.emf';(P/filename).write_bytes(emf(rs));manifest.append({'file':filename,'classification':classification})

emit('square')
emit('triangle',brush(TRIANGLE,center=(32.5,24.5)))
emit('quad-offcenter',brush(center=(20.5,24.5)))
emit('quad-multicolor',brush(colors=(RED,GREEN,BLUE,WHITE),center_color=0xffffff00))
emit('triangle-multicolor',brush(TRIANGLE,center=(32.5,24.5),colors=(RED,GREEN,BLUE),center_color=WHITE))
emit('concave',brush(CONCAVE,center=(16.5,16.5)))
emit('center-outside',brush(center=(64.5,32.5)),classification='supported-windows-reference')
for name,focus in [('zero',(0,0)),('xy',(.3,.7)),('one',(1,1))]:emit('focus-'+name,brush(focus=focus))
emit('focus-offcenter',brush(center=(20.5,24.5),focus=(.3,.7)),classification='supported-windows-reference')
emit('focus-multicolor',brush(colors=(RED,GREEN,BLUE,WHITE),center_color=0xffffff00,focus=(.3,.7)),classification='supported-windows-reference')
emit('preset-multicolor',brush(colors=(RED,GREEN,BLUE,WHITE),center_color=0xffffff00,stops=[(0,BLUE),(.5,GREEN),(1,RED)]),classification='supported-windows-reference')
emit('blend-multicolor',brush(colors=(RED,GREEN,BLUE,WHITE),center_color=0xffffff00,blend=[(0,0),(.25,0),(.75,1),(1,1)]),classification='supported-windows-reference')
emit('surround-two',brush(colors=(RED,BLUE)),classification='supported-windows-reference')
emit('surround-excess',brush(colors=(RED,GREEN,BLUE,WHITE,RED)),classification='supported-windows-reference')
emit('concave-outsidekernel',brush(CONCAVE,center=(40.5,16.5)),classification='supported-windows-reference')
for gamma in [False,True]:
 linear=U(V,4,0x80 if gamma else 0,4)+F(8.5,8.5,48,48)+U(RED,BLUE,RED,BLUE)
 emit('linear-gamma-'+('on' if gamma else 'off'),linear,classification='supported-windows-reference')
emit('gamma',brush(gamma=True))
emit('alpha',brush(center_color=0x80ff0000,colors=(0x400000ff,)))
emit('gamma-alpha',brush(gamma=True,center_color=0x80ff0000,colors=(0x400000ff,)))
emit('brush-transform',brush(points=[(4.25,4.25),(28.25,4.25),(28.25,28.25),(4.25,28.25)],center=(16.25,16.25),transform=(2,0,0,2,0,0)))
emit('world-transform',brush(points=[(4.25,4.25),(28.25,4.25),(28.25,28.25),(4.25,28.25)],center=(16.25,16.25)),prefix=[ep(0x402A,F(2,0,0,2,0,0))])
emit('sheared',brush(transform=(1,0,.25,1,-8,0)))
for mode in range(4):emit('wrap-'+str(mode),brush(wrap=mode),classification='supported-windows-reference')
emit('preset',brush(stops=[(0,BLUE),(.25,BLUE),(.75,RED),(1,RED)]))
emit('blend',brush(blend=[(0,0),(.25,0),(.75,1),(1,1)]))
emit('cardinal-boundary',brush(boundary_path=False),classification='supported-windows-reference')
# Shared paint consumers; the same brush must not fall back to an SVG default.
pen=U(V,0,0,2)+F(8)+brush(colors=(RED,GREEN,BLUE,WHITE),center_color=WHITE)
emit('pen',draw=[ep(0x4008,pen,0x201),ep(0x400D,U(2)+F(8.5,32.5,56.5,32.5),1)])
face='Helvetica'.encode('utf-16le');font=U(V)+F(40)+U(2,0,0,len(face)//2)+face
text='M'.encode('utf-16le')
emit('glyph',draw=[ep(0x4008,font,0x601),ep(0x401C,U(0,0xffffffff,len(text)//2)+F(8,8,48,48)+text,1)])
emit('clip',prefix=[ep(0x4032,F(16,16,32,32))])
emit('sourcecopy',brush(center_color=0x80ff0000,colors=(0x400000ff,)),prefix=[ep(0x4023,b'',1)])
# Refused records follow a valid red primitive; errors must not expose earlier
# paint as a successful partial image. Some valid-but-unsupported families are
# named separately from structurally malformed records in the manifest.
valid_prefix=[ep(0x400A,U(0xffff0000,1)+F(0,0,8,8),0x8000)]
def refused(name,b,classification='malformed'):
 emit('refused-'+name,b,prefix=valid_prefix,classification=classification)
refused('colors-empty',brush(colors=()))
emit('surround-excess-after-paint',brush(colors=(RED,GREEN,BLUE,WHITE,RED)),prefix=valid_prefix,classification='supported-derived-after-paint')
refused('path-truncated',brush(raw_path=U(V,4,0)+F(8,8)))
refused('center-nonfinite',brush(center=(float('nan'),32)))
refused('focus-truncated',brush(focus=(.3,.7))[:-4])
refused('focus-nonfinite',brush(focus=(float('inf'),.3)))
refused('wrap-invalid',brush(wrap=5))
refused('transform-singular',brush(transform=(0,0,0,0,0,0)))
refused('preset-unsorted',brush(stops=[(0,BLUE),(.8,RED),(.4,GREEN),(1,RED)]))
refused('blend-unsorted',brush(blend=[(0,0),(.8,.2),(.4,.8),(1,1)]))
refused('self-crossing',brush(points=[(8.5,8.5),(56.5,56.5),(56.5,8.5),(8.5,56.5)]),classification='valid-unsupported-candidate')
refused('multi-subpath',brush(raw_path=path(SQUARE+TRIANGLE,[0,1,1,0x81,0,1,0x81])),classification='valid-unsupported-candidate')
# 1024 simple vertices, 512x512 canvas: a small wire object whose
# >268M edge/pixel candidate work must be refused before expensive raster work.
ring=[(256+240*math.cos(2*math.pi*i/1024),256+240*math.sin(2*math.pi*i/1024)) for i in range(1024)]
budget_name='path-gradient-refused-raster-work-budget.emf'
budget_records=[ep(0x4009,U(WHITE)),*valid_prefix,ep(0x4008,brush(ring,center=(256,256)),0x100),ep(0x400A,U(0,1)+F(0,0,512,512))]
(P/budget_name).write_bytes(emf(budget_records,512,512))
manifest.append({'file':budget_name,'classification':'bounded-work-budget','canvas':[512,512]})
for entry in manifest:
 if entry['file']=='path-gradient-surround-excess-after-paint.emf':
  entry.update(previousDraftName='path-gradient-refused-colors-excess.emf',relatedWindowsCase='path-gradient-surround-excess.emf',independentlyWindowsRendered=False)
for native in sorted(P.glob('path-gradient-native-linear-alpha-*.emf')):
 manifest.append({'file':native.name,'classification':'native-GDI+-recorded','generation':'Retained Windows synthetic recording; not regenerated by this Python wire author'})
reference=P/'path-gradient-windows-reference.json'
if reference.is_file():
 sampled={entry['file'] for entry in json.loads(reference.read_text())['cases']}
 for entry in manifest:
  if entry['file'] in sampled:entry['classification']='supported-windows-reference'
(P/'path-gradient-manifest.json').write_text(json.dumps({'kind':'OriginalPathGradientWireCorpus','canvas':[64,64],'notes':'No expected pixels are calculated by the generator. The independent Windows-reference JSON binds sampled cases to exact source bytes. Native-recorded alpha controls are retained separately.','cases':manifest},indent=2)+'\n')
print('Indexed '+str(len(manifest))+' path-gradient fixtures (including retained native Windows recordings); old corpus untouched')
