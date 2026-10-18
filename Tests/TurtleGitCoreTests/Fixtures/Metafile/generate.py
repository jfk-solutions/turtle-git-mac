#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Original synthetic records following Microsoft MS-EMF/MS-EMFPLUS/MS-WMF.
# No upstream picture or font bytes are copied. Deterministic, no dependencies.
import struct,zlib,pathlib
P=pathlib.Path(__file__).parent
U=lambda *v:struct.pack('<'+'I'*len(v),*v)
I=lambda *v:struct.pack('<'+'i'*len(v),*v)
F=lambda *v:struct.pack('<'+'f'*len(v),*v)
H=lambda *v:struct.pack('<'+'H'*len(v),*v)
def pad(b):return b+b'\0'*((-len(b))%4)
def record(t,b=b''):return U(t,len(pad(b))+8)+pad(b)
def emf(records,w=96,h=64,physical_scale=1):
 records=records+[record(14,U(0,0,20))]
 header=U(1,88)+I(0,0,w,h)+I(0,0,round(w*2540/96*physical_scale),round(h*2540/96*physical_scale))+U(0x464d4520,0x10000,88+sum(map(len,records)),len(records)+1)+H(16,0)+U(0,0,0)+I(960,960,254,254)
 assert len(header)==88
 return header+b''.join(records)
def ep(t,body=b'',flags=0):return H(t,flags)+U(12+len(pad(body)),len(body))+pad(body)
def plus(records):
 stream=ep(0x4001,U(0xdbc01002,0,96,96),1)+b''.join(records)+ep(0x4002)
 return emf([record(70,U(len(stream)+4)+b'EMF+'+stream)])
def brush(handle,color):return record(39,U(handle,0,color,0))
def selected(handle):return record(37,U(handle))
vector=[brush(1,0xff),selected(1),record(43,I(4,4,28,28)),brush(2,0xff0000),selected(2),record(59),record(27,I(40,4)),record(54,I(64,4)),record(54,I(64,28)),record(61),record(60),record(62,I(40,4,64,28))]
(P/'classic-vector.emf').write_bytes(emf(vector))
(P/'physical-frame.emf').write_bytes(emf(vector,physical_scale=2))
# Top-down 2x2 BGRA bitmap red/green, blue/white; source RGB compression ignores alpha.
pixels=bytes([0,0,255,255,0,255,0,255,255,0,0,255,255,255,255,255])
bmi=U(40)+I(2,-2)+H(1,32)+U(0,len(pixels),0,0,0,0)
body=I(8,8,40,40)+I(8,8,0,0,2,2)+U(80,len(bmi),120,len(pixels),0,0xcc0020)+I(32,32)+bmi+pixels
(P/'classic-bitmap.emf').write_bytes(emf([record(81,body)]))
# Indexed saves restore matrix and clipping; blue rectangle must not retain red translation.
rs=[ep(0x4025,U(17)),ep(0x402D,F(12,4),0x2000),ep(0x4032,F(0,0,16,16)),ep(0x400A,U(0xffff0000,1)+F(0,0,24,24),0x8000),ep(0x4026,U(17)),ep(0x400A,U(0xff0000ff,1)+F(48,4,20,20),0x8000)]
(P/'plus-transform.emf').write_bytes(plus(rs))
# Native bitmap callback, original font family, and a multi-subpath fill.
image=U(0xdbc01002,1)+I(2,2,8)+U(0x26200a,0)+pixels
face='Helvetica'.encode('utf-16le');font=U(0xdbc01002)+F(12)+U(2,0,0,len(face)//2)+face
text='TurtleGit'.encode('utf-16le')
rs=[ep(0x4008,image,0x500),ep(0x401A,U(0,2)+F(0,0,2,2)+F(4,4,32,32)),ep(0x4008,font,0x601),ep(0x401C,U(0xff000000,0xffffffff,len(text)//2)+F(40,8,52,24)+text,0x8001)]
(P/'plus-bitmap-text.emf').write_bytes(plus(rs))
# Compressed PNG path has ignored zero width/height in EMF+ Bitmap metadata.
def chunk(t,b):return struct.pack('>I',len(b))+t+b+struct.pack('>I',zlib.crc32(t+b)&0xffffffff)
png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',2,2,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(b'\0'+bytes([255,0,0,255,0,255,0,255])+b'\0'+bytes([0,0,255,255,255,255,255,255])))+chunk(b'IEND',b'')
image=U(0xdbc01002,1)+I(0,0,0)+U(0,1)+png
rs=[ep(0x4008,image,0x500),ep(0x401B,U(0,2)+F(1,0,1,2)+U(3)+F(8,8,40,8,8,40))]
(P/'plus-compressed-crop.emf').write_bytes(plus(rs))
# Placeable WMF clip rectangle + solid red brush. All logical units are pixels at96dpi.
def wr(t,b=b''):
 if len(b)%2:b+=b'\0'
 return U((6+len(b))//2)+H(t)+b
rs=[wr(0x20b,struct.pack('<hh',0,0)),wr(0x20c,struct.pack('<hh',64,96)),wr(0x2fc,H(0)+U(0xff)+H(0)),wr(0x12d,H(0)),wr(0x416,struct.pack('<hhhh',28,28,4,4)),wr(0x41b,struct.pack('<hhhh',40,40,0,0)),wr(0)]
ph=U(0x9ac6cdd7)+H(0)+struct.pack('<hhhh',0,0,96,64)+H(96)+U(0)
checksum=0
for word in struct.unpack('<10H',ph):checksum^=word
header=H(1,9,0x300)+U((18+sum(map(len,rs)))//2)+H(4)+U(max(len(x)//2 for x in rs))+H(0)
(P/'clip-vector.wmf').write_bytes(ph+H(checksum)+header+b''.join(rs))
# Unsupported painting must throw rather than return a white but successful image.
(P/'unsupported-region.emf').write_bytes(plus([ep(0x4013,U(0xffff0000),0x8000)]))
(P/'unsupported-rop.emf').write_bytes(emf([record(20,U(7)),*vector]))
# Same logical raster extent, different source physical resolution.
wmf=bytearray((P/'clip-vector.wmf').read_bytes());wmf[14:16]=H(144);checksum=0
for word in struct.unpack('<10H',wmf[:20]):checksum^=word
wmf[20:22]=H(checksum);(P/'clip-144dpi.wmf').write_bytes(wmf)
# Dual fallback intentionally paints a different color. GDI+ selects red EMF+,
# except the explicit GetDC interval which contributes the blue rectangle.
def comment(records):
 stream=b''.join(records);return record(70,U(len(stream)+4)+b'EMF+'+stream)
rs=[comment([ep(0x4001,U(0xdbc01002,1,96,96),1),ep(0x400A,U(0xffff0000,1)+F(4,4,24,24),0x8000)]),brush(1,0xff00),selected(1),record(43,I(4,4,28,28)),comment([ep(0x4004)]),brush(2,0xff0000),selected(2),record(43,I(48,4,68,24)),comment([ep(0x4002)])]
(P/'plus-dual-getdc.emf').write_bytes(emf(rs))
# Noncommuting operations distinguish GDI+ row-vector Append and Prepend.
rs=[ep(0x4025,U(1)),ep(0x402E,F(2,2)),ep(0x402D,F(12,0),0x2000),ep(0x400A,U(0xffff0000,1)+F(0,0,8,8),0x8000),ep(0x4026,U(1)),ep(0x402E,F(2,2)),ep(0x402D,F(12,0)),ep(0x400A,U(0xff0000ff,1)+F(0,16,8,8),0x8000)]
(P/'plus-matrix-order.emf').write_bytes(plus(rs))
# Exact path object and container source/destination mapping, followed by restored state.
path=U(0xdbc01002,3,0)+F(0,0,16,0,0,16)+bytes([0,1,0x81])
rs=[ep(0x4008,path,0x302),ep(0x4027,F(32,8,32,32,0,0,16,16)+U(6),2),ep(0x4014,U(0xffff0000),0x8002),ep(0x4029,U(6)),ep(0x400A,U(0xff0000ff,1)+F(4,40,16,16),0x8000)]
(P/'plus-path-container.emf').write_bytes(plus(rs))
# Each continued fragment carries total size, including the final flagged fragment.
raw=U(0xdbc01002,1)+I(2,2,8)+U(0x26200a,0)+pixels
rs=[ep(0x4008,U(len(raw))+raw[:20],0x8500),ep(0x4008,U(len(raw))+raw[20:],0x8500),ep(0x401A,U(0,2)+F(0,0,2,2)+F(4,4,32,32))]
(P/'plus-continued-bitmap.emf').write_bytes(plus(rs))
