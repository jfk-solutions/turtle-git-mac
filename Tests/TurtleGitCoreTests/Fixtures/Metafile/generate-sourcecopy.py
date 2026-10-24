#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Original EMF+ SourceCopy records, isolated-paint and literal PNG controls.
Microsoft source contracts (not a Windows pixel oracle):
https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/d7ace3ef-2092-4e94-89da-103ac3f9ac5f
https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/cbfc8c78-778d-466e-a52a-a82f8ce6cfee
https://learn.microsoft.com/en-us/windows/win32/api/gdiplusgraphics/nf-gdiplusgraphics-graphics-setcompositingmode
Only sourcecopy-* and sourceover-* authored outputs are written.
"""
from pathlib import Path
import struct,zlib,binascii
P=Path(__file__).parent
U=lambda *v:struct.pack('<'+'I'*len(v),*v)
I=lambda *v:struct.pack('<'+'i'*len(v),*v)
H=lambda *v:struct.pack('<'+'H'*len(v),*v)
F=lambda *v:struct.pack('<'+'f'*len(v),*v)
def pad(b):return b+b'\0'*((-len(b))%4)
def rec(t,b=b''):return U(t,8+len(pad(b)))+pad(b)
def ep(t,b=b'',flags=0):return H(t,flags)+U(12+len(pad(b)),len(b))+pad(b)
def comment(records):
 b=b'EMF+'+b''.join(records);return rec(70,U(len(b))+b)
def emf(records):
 records=records+[rec(14,U(0,0,20))]
 return U(1,88)+I(0,0,64,64)+I(0,0,1693,1693)+U(0x464d4520,0x10000,88+sum(map(len,records)),len(records)+1)+H(32,0)+U(0,0,0)+I(960,960,254,254)+b''.join(records)
HEADER=ep(0x4001,U(0xdbc01002,1,96,96),1)
def plus(records):return emf([comment([HEADER]+records+[ep(0x4002)])])
def fill(color,rect=(8,8,48,48)):return ep(0x400A,U(color,1)+F(*rect),0x8000)
BLUE=0xff0000ff
BACKGROUND=fill(BLUE,(0,0,64,64))
def mode(value=1):return ep(0x4023,flags=value)
def write(name,records): (P/(name+'.emf')).write_bytes(plus(records))
def family(name,records):
 write('sourcecopy-'+name,[BACKGROUND,mode()]+records)
 write('sourceover-'+name,[BACKGROUND,mode(0)]+records)
 write('sourcecopy-'+name+'-isolated',[ep(0x4009,U(0)),mode(0)]+records)
def png(name,pixel):
 def chunk(k,b):return UBE(len(b))+k+b+UBE(binascii.crc32(k+b)&0xffffffff)
 UBE=lambda n:struct.pack('>I',n)
 raw=b''.join(b'\0'+b''.join(bytes(pixel(x,y)) for x in range(64)) for y in range(64))
 data=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',64,64,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b'')
 (P/(name+'.png')).write_bytes(data)
for label,color,rgba,over in [('transparent',0x00ff0000,(255,0,0,0),(0,0,255,255)),('semi',0x80ff0000,(255,0,0,128),(128,0,127,255)),('opaque',0xffff0000,(255,0,0,255),(255,0,0,255))]:
 family('solid-'+label,[fill(color)])
 for prefix,value in [('sourcecopy',rgba),('sourceover',over)]:png(prefix+'-solid-'+label+'-control',lambda x,y,v=value:v if 8<=x<56 and 8<=y<56 else (0,0,255,255))
# The same record carries two overlapping fills: each rectangle is a distinct
# ordered paint, not a source-over union flattened before replacement.
write('sourcecopy-overlapping-rects',[BACKGROUND,mode(),ep(0x400A,U(0x80ff0000,2)+F(8,8,32,32,24,24,32,32),0x8000)])
write('sourcecopy-reserved-flags',[BACKGROUND,mode(0xab01),fill(0x00ff0000)])
# Geometric masks cannot be inferred from opacity: transparent hatch/texture
# cells still replace blue under SourceCopy. Isolated scenes preserve exact
# native geometry while the solid/image PNGs independently name literal pixels.
gradient=U(0xdbc01002,4,0,4)+F(8,8,48,48)+U(0x00ff0000,0x8000ff00,0x00ff0000,0x8000ff00)
family('gradient',[ep(0x4008,gradient,0x100),ep(0x400A,U(0,1)+F(8,8,48,48))])
hatch=U(0xdbc01002,1,0,0x80ff0000,0x0000ff00)
family('hatch',[ep(0x4008,hatch,0x100),ep(0x400A,U(0,1)+F(8,8,48,48))])
image=U(0xdbc01002,1)+I(2,2,8)+U(0x26200a,0)+bytes([0,0,255,0,0,255,0,128,255,0,0,255,0,0,255,64])
texture=U(0xdbc01002,2,2,4)+F(24,0,0,24,8,8)+image
family('texture',[ep(0x4008,texture,0x100),ep(0x400A,U(0,1)+F(8,8,48,48))])
imageRecords=[ep(0x4008,image,0x500),ep(0x401A,U(0xffffffff,2)+F(0,0,2,2)+F(8,8,48,48))]
family('image',imageRecords)
family('image-affine',[ep(0x4008,image,0x500),ep(0x4032,F(8,8,48,48)),ep(0x401B,U(0xffffffff,2)+F(0,0,2,2)+U(3)+F(8,8,56,8,8,56))])
# Explicit independent straight-alpha PNG: top-left transparent, top-right
# half-green, bottom-left opaque blue, bottom-right quarter-red.
quad=[(255,0,0,0),(0,255,0,128),(0,0,255,255),(255,0,0,64)]
png('sourcecopy-image-control',lambda x,y:quad[(y>=32)*2+(x>=32)] if 8<=x<56 and 8<=y<56 else (0,0,255,255))
pen=lambda color:U(0xdbc01002,0,0,2)+F(8)+U(0xdbc01002,0,color)
family('stroke',[ep(0x4008,pen(0x80ff0000),0x200),ep(0x400D,U(2)+F(12,32,52,32))])
family('stroke-transparent',[ep(0x4008,pen(0x00ff0000),0x200),ep(0x400D,U(2)+F(12,32,52,32))])
points=[(8,8),(56,8),(56,56),(8,56),(24,24),(40,24),(40,40),(24,40)]
path=U(0xdbc01002,len(points),0)+b''.join(F(*p) for p in points)+bytes([0,1,1,0x81,0,1,1,0x81])
family('path-hole',[ep(0x4008,path,0x302),ep(0x4014,U(0x00ff0000),0x8002)])
region=U(0xdbc01002,0,0x10000001,len(path))+path
family('region-hole',[ep(0x4008,region,0x402),ep(0x4013,U(0x00ff0000),0x8002)])
write('sourcecopy-path-clip',[BACKGROUND,ep(0x4008,path,0x302),ep(0x4033,flags=2),mode(),fill(0x00ff0000,(0,0,64,64))])
face='Helvetica'.encode('utf-16le');font=U(0xdbc01002)+F(20)+U(2,0,0,len(face)//2)+face;text='HH'.encode('utf-16le')
family('glyph',[ep(0x4008,font,0x601),ep(0x401C,U(0x80ff0000,0xffffffff,2)+F(8,8,48,40)+text,0x8001)])
family('positioned-glyph',[ep(0x4008,font,0x601),ep(0x4036,U(0x80ff0000,1,0,2)+text+F(12,32,36,32),0x8001)])
write('sourcecopy-state',[BACKGROUND,mode(),ep(0x4025,U(7)),mode(0),fill(0x8000ff00,(8,8,16,16)),ep(0x4026,U(7)),fill(0x00ff0000,(40,8,16,16)),ep(0x4028,U(9)),mode(0),fill(0x80ff0000,(8,40,16,16)),ep(0x4029,U(9)),fill(0x80ff0000,(40,40,16,16))])
write('sourcecopy-clip-transform',[BACKGROUND,mode(),ep(0x4025,U(11)),ep(0x402D,F(8,8)),ep(0x4032,F(0,0,24,24)),fill(0x00ff0000,(-8,-8,48,48)),ep(0x4026,U(11))])
for m in [0,1]:
 write('sourcecopy-clear-mode'+str(m),[BACKGROUND,mode(m),ep(0x4009,U(0x80ff0000))])
 write('sourcecopy-clear-continuity'+str(m),[BACKGROUND,mode(m),ep(0x4009,U(0x80ff0000)),fill(0x8000ff00,(8,8,16,16))])
# Dual EMF+ GetDC: classic GDI contributes opaque green, while the next EMF+
# paint resumes its saved SourceCopy state. No invented classic alpha record.
records=[comment([HEADER,BACKGROUND,mode(),fill(0x00ff0000,(8,8,16,16)),ep(0x4004)]),rec(39,U(1,0,0x00ff00,0)),rec(37,U(1)),rec(37,U(0x80000008)),rec(43,I(40,8,56,24)),comment([fill(0x00ff0000,(8,40,16,16)),fill(0x80ff0000,(40,40,16,16)),ep(0x4002)])]
(P/'sourcecopy-getdc.emf').write_bytes(emf(records))
# Refusals all contain visible valid earlier paint. Never return that prefix.
invalid={
 'mode':mode(2),
 'mode-data':ep(0x4023,U(0),1),
 'missing-brush':ep(0x400A,U(63,1)+F(8,8,48,48)),
 'image-truncated':ep(0x4008,image[:-3],0x500)+ep(0x401A,U(0xffffffff,2)+F(0,0,2,2)+F(8,8,48,48)),
 'nonfinite-geometry':fill(0x80ff0000,(8,8,float('nan'),48)),
 'cleartype':ep(0x401F,flags=5)+ep(0x4008,font,0x601)+ep(0x401C,U(0x80ff0000,0xffffffff,2)+F(8,8,48,40)+text,0x8001),
}
for name,record in invalid.items():write('sourcecopy-refused-'+name,[BACKGROUND,fill(0xffff0000,(0,0,16,16)),mode(),record])
