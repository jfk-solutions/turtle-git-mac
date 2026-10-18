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
rs=[ep(0x4008,image,0x500),ep(0x401A,U(0xffffffff,2)+F(0,0,2,2)+F(4,4,32,32)),ep(0x4008,font,0x601),ep(0x401C,U(0xff000000,0xffffffff,len(text)//2)+F(40,8,52,24)+text,0x8001)]
(P/'plus-bitmap-text.emf').write_bytes(plus(rs))
# Compressed PNG path has ignored zero width/height in EMF+ Bitmap metadata.
def chunk(t,b):return struct.pack('>I',len(b))+t+b+struct.pack('>I',zlib.crc32(t+b)&0xffffffff)
png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',2,2,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(b'\0'+bytes([255,0,0,255,0,255,0,255])+b'\0'+bytes([0,0,255,255,255,255,255,255])))+chunk(b'IEND',b'')
image=U(0xdbc01002,1)+I(0,0,0)+U(0,1)+png
rs=[ep(0x4008,image,0x500),ep(0x401B,U(0xffffffff,2)+F(1,0,1,2)+U(3)+F(8,8,40,8,8,40))]
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
rs=[ep(0x4008,U(len(raw))+raw[:20],0x8500),ep(0x4008,U(len(raw))+raw[20:],0x8500),ep(0x401A,U(0xffffffff,2)+F(0,0,2,2)+F(4,4,32,32))]
(P/'plus-continued-bitmap.emf').write_bytes(plus(rs))

# Painting-family fixtures, independently authored from MS-EMFPLUS structures.
# ImageAttributesID UINT_MAX is the optional-object sentinel; ID0 is our image,
# so it must never masquerade as ImageAttributes. ID3 below is a real type8.
compressed_image=U(0xdbc01002,1)+I(0,0,0)+U(0,1)+png
def attr(wrap=4,color=0,clamp=0):return U(0xdbc01002,0,wrap,color,clamp,0)
def image_objects(attributes=None):
 return [ep(0x4008,compressed_image,0x500)]+([] if attributes is None else [ep(0x4008,attributes,0x803)])
def image_rect(attributes=0xffffffff,source=(0,0,2,2),dest=(8,8,32,32)):
 return ep(0x401A,U(attributes,2)+F(*source)+F(*dest))
(P/'plus-image-attributes.emf').write_bytes(plus(image_objects(attr())+[image_rect(3)]))
# Explicit magenta clamp color must paint both out-of-source sides; interior
# green remains the original image pixel (no recoloring of in-bounds pixels).
(P/'plus-image-clamp.emf').write_bytes(plus(image_objects(attr(color=0xffff00ff))+[image_rect(3,(-1,0,4,2),(8,8,64,32))]))
# Two rows cover Tile and TileFlipX image attributes. Source pixels cross both
# negative and positive image boundaries; centers analytically map to x8+16n.
rs=image_objects(attr(wrap=0))+[image_rect(3,(-2,0,6,2),(0,8,96,16)),ep(0x4008,attr(wrap=1),0x803),image_rect(3,(-2,0,6,2),(0,36,96,16))]
(P/'plus-image-wrap.emf').write_bytes(plus(rs))
# PointR uses signed 7/15-bit scalars, high bit first-byte length. Unlike usual
# little-endian Int16, Integer15's payload high seven bits precede its low byte.
def relative_scalar(value):
 assert -16384<=value<=16383
 if -64<=value<=63:return bytes([value&0x7f])
 value &= 0x7fff
 return bytes([0x80|(value>>8),value&255])
relative_points=b''.join(relative_scalar(v) for v in (160,8,-128,0,128,32))
# C is deliberately also set: P makes C undefined/ignored. Both signs and widths
# occur. World scale then translation maps red/green/blue centers to68,20/36,20/68,36.
rs=image_objects()+[ep(0x402A,F(.5,0,0,1,4,4)),ep(0x401B,pad(U(0xffffffff,2)+F(0,0,2,2)+U(3)+relative_points),0x4800)]
(P/'plus-image-relative.emf').write_bytes(plus(rs))
# C without P means signed absolute Int16, including a negative initial x.
points=struct.pack('<hhhhhh',-16,8,48,8,-16,40)
rs=image_objects()+[ep(0x402D,F(24,4)),ep(0x401B,U(0xffffffff,2)+F(0,0,2,2)+U(3)+points,0x4000)]
(P/'plus-image-int16.emf').write_bytes(plus(rs))
# E(0x2000) is an effect flag, NOT relative point encoding. A missing/unsupported
# effect pipeline must refuse this draw rather than silently render unmodified.
(P/'unsupported-image-effect.emf').write_bytes(plus(image_objects()+[ep(0x401B,U(0xffffffff,2)+F(0,0,2,2)+U(3)+F(8,8,40,8,8,40),0x2000)]))
(P/'unsupported-image-attributes.emf').write_bytes(plus(image_objects(attr(clamp=1))+[image_rect(3)]))
(P/'unsupported-image-wrap.emf').write_bytes(plus(image_objects(attr(wrap=5))+[image_rect(3)]))
(P/'unsupported-image-attribute-type.emf').write_bytes(plus(image_objects()+[image_rect(0)]))
# Three precise preset colors; no copied CSS, pictures, expected SVG or fonts.
def preset(stops):return U(len(stops))+F(*(p for p,c in stops))+U(*(c for p,c in stops))
colors=[(0,0xffff0000),(.5,0xff00ff00),(1,0xff0000ff)]
def linear(wrap=0,transform=None,stops=colors):
 flags=4|(2 if transform is not None else 0)
 return U(0xdbc01002,4,flags,wrap)+F(0,0,1,1)+U(stops[0][1],stops[-1][1],stops[0][1],stops[-1][1])+(F(*transform) if transform is not None else b'')+preset(stops)
# Brush rotation/scaling/translation and separate world translation are both
# required. Diagonal normalized sample fractions give unambiguous color stops.
rs=[ep(0x4008,linear(transform=(0,48,-24,0,64,4)),0x100),ep(0x402D,F(8,4)),ep(0x400A,U(0,1)+F(40,4,24,48))]
(P/'plus-gradient-transform.emf').write_bytes(plus(rs))
# Same second-period location is red for Tile, blue for TileFlipX. Bands keep
# world origins separate and distinguish repeated from reflected stop order.
rs=[ep(0x4008,linear(wrap=0,transform=(16,0,0,16,0,0)),0x100),ep(0x4025,U(5)),ep(0x402D,F(8,4)),ep(0x400A,U(0,1)+F(0,0,80,20)),ep(0x4026,U(5)),ep(0x4008,linear(wrap=1,transform=(16,0,0,16,0,0)),0x100),ep(0x402D,F(8,36)),ep(0x400A,U(0,1)+F(0,0,80,20))]
(P/'plus-gradient-wrap.emf').write_bytes(plus(rs))
# Invalid stop order cannot yield an approximate or successful blank painting.
(P/'unsupported-gradient-stops.emf').write_bytes(plus([ep(0x4008,linear(stops=[(0,0xffff0000),(.75,0xff00ff00),(.5,0xff0000ff)]),0x100),ep(0x400A,U(0,1)+F(0,0,96,64))]))
# Centered elliptical path gradient: preset positions run boundary0 -> center1
# in GDI+, so the radial expected center is red, middle green, boundary blue.
# Endpoint plateaus make endpoint color assertions exact; the source center is
# half-pixel aligned so device pixel(54,38) samples the exact center(54.5,38.5).
k=.5522847498307936;cx,cy,rx,ry=48.5,32.5,24,20
ellipse=[(cx+rx,cy),(cx+rx,cy+ry*k),(cx+rx*k,cy+ry),(cx,cy+ry),(cx-rx*k,cy+ry),(cx-rx,cy+ry*k),(cx-rx,cy),(cx-rx,cy-ry*k),(cx-rx*k,cy-ry),(cx,cy-ry),(cx+rx*k,cy-ry),(cx+rx,cy-ry*k),(cx+rx,cy)]
path=U(0xdbc01002,len(ellipse),0)+F(*(v for point in ellipse for v in point))+pad(bytes([0]+[3]*11+[0x83]))
radial=U(0xdbc01002,3,1|2|4,4,0xffff0000)+F(cx,cy)+U(1,0xff0000ff,len(path))+path+F(1,0,0,1,2,2)+preset([(0,0xff0000ff),(.1,0xff0000ff),(.5,0xff00ff00),(.9,0xffff0000),(1,0xffff0000)])
rs=[ep(0x4008,radial,0x100),ep(0x402D,F(4,4)),ep(0x400E,U(0)+F(26.5,14.5,48,40))]
(P/'plus-gradient-radial.emf').write_bytes(plus(rs))
# BlendFactorsH specifies end-color weights, not additional preset colors.
# Plateau intervals remain exactly red/blue; the midpoint mixes both equally.
blend=U(0xdbc01002,4,2|8,0)+F(0,0,1,1)+U(0xffff0000,0xff0000ff,0xffff0000,0xff0000ff)+F(80,0,0,32,8,8)+U(4)+F(0,.25,.75,1)+F(0,0,1,1)
(P/'plus-gradient-blend.emf').write_bytes(plus([ep(0x4008,blend,0x100),ep(0x400A,U(0,1)+F(8,8,80,32))]))
# SVG backend must retain ARGB alpha for both real Pen objects and inline Brush
# colors. Opaque red width4 line, then half-alpha red rectangle on white.
pen=U(0xdbc01002,0,0,2)+F(4)+U(0,0xffff0000)
rs=[ep(0x4008,pen,0x200),ep(0x400D,U(2)+F(8,8,40,8)),ep(0x400A,U(0x80ff0000,1)+F(8,20,32,24),0x8000)]
(P/'plus-alpha-pen.emf').write_bytes(plus(rs))
# Ordered tile count is valid (100x100 <16384), but duplicating this deterministic
# noisy image into every SVG tile would exceed the aggregate64MiB payload budget.
noise=bytearray();state=0x74757274
for y in range(128):
 noise.append(0)
 for x in range(128):
  for channel in range(3):
   state=(1664525*state+1013904223)&0xffffffff;noise.append(state>>24)
  noise.append(255)
noise_png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',128,128,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(bytes(noise)))+chunk(b'IEND',b'')
noise_image=U(0xdbc01002,1)+I(0,0,0)+U(0,1)+noise_png
rs=[ep(0x4008,noise_image,0x500),ep(0x4008,attr(wrap=0),0x803),image_rect(3,(0,0,12800,12800),(0,0,96,64))]
(P/'unsupported-image-tile-budget.emf').write_bytes(plus(rs))
# Float32 precision at a huge offset must not turn a visibly distorted ellipse
# into an accepted canonical radial gradient. Old maxCoordinate*3e-7 tolerance
# (~270) admitted this256-unit control shift; world scale makes it7.68pixels.
large=900000000;radius=1024
large_ellipse=[(large+radius,large),(large+radius,large+radius*k),(large+radius*k,large+radius),(large,large+radius),(large-radius*k,large+radius),(large-radius,large+radius*k),(large-radius,large),(large-radius,large-radius*k),(large-radius*k,large-radius),(large,large-radius),(large+radius*k,large-radius),(large+radius,large-radius*k),(large+radius,large)]
large_ellipse[1]=(large_ellipse[1][0]+256,large_ellipse[1][1])
large_path=U(0xdbc01002,13,0)+F(*(v for point in large_ellipse for v in point))+pad(bytes([0]+[3]*11+[0x83]))
large_radial=U(0xdbc01002,3,1,4,0xffff0000)+F(large,large)+U(1,0xff0000ff,len(large_path))+large_path
rs=[ep(0x4008,large_radial,0x100),ep(0x402A,F(.03,0,0,.03,48-large*.03,32-large*.03)),ep(0x400E,U(0)+F(large-radius,large-radius,2*radius,2*radius))]
(P/'unsupported-gradient-precision.emf').write_bytes(plus(rs))
