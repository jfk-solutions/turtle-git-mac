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
def plus(records,w=96,h=64):
 stream=ep(0x4001,U(0xdbc01002,0,96,96),1)+b''.join(records)+ep(0x4002)
 return emf([record(70,U(len(stream)+4)+b'EMF+'+stream)],w,h)
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

# Region/pattern family: original binary records, with independent Boolean and
# source-pixel expectations in MetafileImageTests. RegionNodeCount counts CHILD
# nodes, excluding the root. Paths retain their own GraphicsVersion header.
def region_rect(x,y,w,h):return (U(0x10000000)+F(x,y,w,h),1)
def region_terminal(t):return (U(t),1)
def region_op(t,a,b):return (U(t)+a[0]+b[0],1+a[1]+b[1])
def region_path(points,types=None,flags=0):
 types=types or ([0]+[1]*(len(points)-2)+[0x81])
 path=U(0xdbc01002,len(points),flags)+(struct.pack('<'+'h'*(2*len(points)),*(v for point in points for v in point)) if flags==0x4000 else F(*(v for point in points for v in point)))+pad(bytes(types))
 return (U(0x10000001,len(path))+path,1)
def region(node):return U(0xdbc01002,node[1]-1)+node[0]
def region_object(node,id=2):return ep(0x4008,region(node),0x400|id)
def region_fill(color=0xffff0000,id=2,inline=True):return ep(0x4013,U(color),(0x8000 if inline else 0)|id)
a,b=region_rect(8,8,48,40),region_rect(32,8,48,40)
for op,name in [(1,'and'),(2,'or'),(3,'xor'),(4,'exclude'),(5,'complement')]:
 (P/('plus-region-'+name+'.emf')).write_bytes(plus([region_object(region_op(op,a,b)),region_fill()]))
# Each clip combine has independently known A-only, intersection, B-only and
# outside samples. SetClipRegion's combine nibble is bits8..11, ID is lowbyte.
for mode in range(6):
 rs=[ep(0x4032,F(8,8,48,40)),region_object(b),ep(0x4034,flags=(mode<<8)|2),ep(0x400A,U(0xffff0000,1)+F(0,0,96,64),0x8000)]
 (P/('plus-region-clip-'+str(mode)+'.emf')).write_bytes(plus(rs))
# One even-odd region path has a genuine hole; a second compressed Int16 path
# keeps its own boundary. Closed contours are not an inferred bounding rectangle.
points=[(8,8),(48,8),(48,48),(8,48),(20,20),(36,20),(36,36),(20,36)]
types=[0,1,1,0x81,0,1,1,0x81]
rs=[region_object(region_path(points,types)),region_fill(),region_object(region_path([(60,8),(88,8),(60,48)],flags=0x4000)),region_fill(0xff0000ff)]
(P/'plus-region-path.emf').write_bytes(plus(rs))
# Infinite/empty leaves participate in Boolean operations, rather than guessed
# huge rectangles. Infinite minus a finite rectangle paints only its complement.
rs=[region_object(region_op(4,region_terminal(0x10000003),region_rect(24,16,32,24))),region_fill(),region_object(region_terminal(0x10000002)),region_fill(0xff0000ff)]
(P/'plus-region-infinite-empty.emf').write_bytes(plus(rs))
# The clip captures the current device mapping. Resetting world transform cannot
# move it; restoring saved state removes it before the blue rectangle paints.
rs=[ep(0x4025,U(17)),region_object(region_rect(0,0,24,24)),ep(0x402D,F(12,4)),ep(0x4034,flags=2),ep(0x402B),ep(0x400A,U(0xffff0000,1)+F(0,0,96,64),0x8000),ep(0x4026,U(17)),ep(0x400A,U(0xff0000ff,1)+F(60,8,16,16),0x8000)]
(P/'plus-region-state.emf').write_bytes(plus(rs))
# Hatch style IDs0..52 each occupy an8x8 cell. Exact Windows bitmap phase is a
# separate physical acceptance item; tests check orientation/colors/nonblank and
# that native device-cell scale survives a world transform.
def hatch(style,fore=0xffff0000,back=0xff0000ff):return U(0xdbc01002,1,style,fore,back)
rs=[]
for style in range(53):
 x,y=2+10*(style%9),2+10*(style//9)
 rs += [ep(0x4008,hatch(style),0x100),ep(0x400A,U(0,1)+F(x,y,8,8))]
(P/'plus-hatch-atlas.emf').write_bytes(plus(rs))
rs=[ep(0x4008,hatch(0,0x80ff0000,0x800000ff),0x100),ep(0x402A,F(2,0,0,2,8,8)),ep(0x400A,U(0,1)+F(0,0,32,20))]
(P/'plus-hatch-alpha-world.emf').write_bytes(plus(rs))
# Embedded EmfPlusImage is the whole image object, not an object-table ID. Pixel
# order is red/green above blue/white; brush scaling leaves broad sample plateaus.
texture_raw=U(0xdbc01002,1)+I(2,2,8)+U(0x26200a,0)+pixels
def texture(wrap=0,transform=(8,0,0,8,24,24),flags=0,image=texture_raw):
 return U(0xdbc01002,2,flags|(2 if transform is not None else 0),wrap)+(F(*transform) if transform is not None else b'')+image
for mode in range(5):
 rs=[ep(0x4008,texture(mode),0x100),ep(0x400A,U(0,1)+F(0,0,96,64))]
 (P/('plus-texture-wrap-'+str(mode)+'.emf')).write_bytes(plus(rs))
for flags,name in [(0,'world'),(0x100,'device')]:
 rs=[ep(0x4008,texture(transform=(8,0,0,8,8,8),flags=flags,image=compressed_image),0x100),ep(0x402A,F(2,0,0,1,4,4)),ep(0x400A,U(0,1)+F(0,0,40,40))]
 (P/('plus-texture-'+name+'.emf')).write_bytes(plus(rs))
alpha_pixels=bytes([0,0,255,128])*4
alpha_image=U(0xdbc01002,1)+I(2,2,8)+U(0x26200a,0)+alpha_pixels
(P/'plus-texture-alpha.emf').write_bytes(plus([ep(0x4008,texture(transform=(16,0,0,16,8,8),image=alpha_image),0x100),ep(0x400A,U(0,1)+F(8,8,48,32))]))
# Pattern brushes also fill nonrectilinear regions through the same paint path.
rs=[region_object(region_op(4,a,region_rect(24,20,16,16))),ep(0x4008,hatch(0),0x101),region_fill(1,inline=False)]
(P/'plus-region-hatch.emf').write_bytes(plus(rs))
rs=[region_object(region_path([(8,8),(88,8),(8,56)])),ep(0x4008,texture(),0x101),region_fill(1,inline=False)]
(P/'plus-region-texture.emf').write_bytes(plus(rs))
# Failures have valid outer chains and only the targeted malformed/unsupported
# object/record contract. No full render can silently accept them as white.
(P/'unsupported-region-count.emf').write_bytes(plus([ep(0x4008,U(0xdbc01002,2)+a[0],0x402),region_fill()]))
(P/'unsupported-region-trailing.emf').write_bytes(plus([ep(0x4008,region(a)+U(0),0x402),region_fill()]))
(P/'unsupported-region-path-length.emf').write_bytes(plus([ep(0x4008,U(0xdbc01002,0,0x10000001,0x7fffffff)+U(0),0x402),region_fill()]))
deep=a
for _ in range(65):deep=region_op(2,deep,region_terminal(0x10000002))
(P/'unsupported-region-depth.emf').write_bytes(plus([region_object(deep),region_fill()]))
(P/'unsupported-region-id.emf').write_bytes(plus([region_object(a),region_fill(id=3)]))
(P/'unsupported-region-clip-mode.emf').write_bytes(plus([region_object(a),ep(0x4034,flags=0x602),ep(0x400A,U(0xffff0000,1)+F(0,0,96,64),0x8000)]))
(P/'unsupported-hatch-style.emf').write_bytes(plus([ep(0x4008,hatch(53),0x100),ep(0x400A,U(0,1)+F(0,0,96,64))]))
(P/'unsupported-texture-flags.emf').write_bytes(plus([ep(0x4008,texture(flags=1),0x100),ep(0x400A,U(0,1)+F(0,0,96,64))]))
(P/'unsupported-texture-wrap.emf').write_bytes(plus([ep(0x4008,texture(wrap=5),0x100),ep(0x400A,U(0,1)+F(0,0,96,64))]))
(P/'unsupported-texture-truncated.emf').write_bytes(plus([ep(0x4008,texture(image=texture_raw[:-5]),0x100),ep(0x400A,U(0,1)+F(0,0,96,64))]))
(P/'unsupported-texture-image.emf').write_bytes(plus([ep(0x4008,texture(image=U(0xdbc01002,1)+I(0,0,0)+U(0,1)+b'not a bitmap'),0x100),ep(0x400A,U(0,1)+F(0,0,96,64))]))
(P/'unsupported-texture-tile-budget.emf').write_bytes(plus([ep(0x4008,texture(transform=(.01,0,0,.01,0,0),image=noise_image),0x100),ep(0x400A,U(0,1)+F(0,0,96,64))]))
# Rendering-origin phase belongs to captured graphics state. Horizontal hatch
# itself stays in device pixels even when separate world coordinates scale.
rs=[ep(0x4008,hatch(0),0x100),ep(0x400A,U(0,1)+F(8,8,32,16)),ep(0x4025,U(41)),ep(0x401D,U(0,3)),ep(0x400A,U(0,1)+F(48,8,32,16)),ep(0x4026,U(41)),ep(0x400A,U(0,1)+F(8,40,32,16))]
(P/'plus-hatch-origin.emf').write_bytes(plus(rs))
# Resource budgets apply to repeated use, not just each individually bounded
# region object. A valid31-node balanced tree is reused beyond65536 nodevisits.
work_region=a
for _ in range(4):work_region=region_op(2,work_region,work_region)
(P/'unsupported-region-work-budget.emf').write_bytes(plus([region_object(work_region)]+[region_fill() for _ in range(2115)]))
(P/'unsupported-region-brush-id.emf').write_bytes(plus([region_object(a),region_fill(3,inline=False)]))
(P/'unsupported-region-path-flags.emf').write_bytes(plus([region_object(region_path([(8,8),(72,8),(8,56)],flags=0x8000)),region_fill()]))
# GammaCorrected marks input as already corrected; no second color transform is
# permitted. Same original bitmap and geometry must retain the ordinary colors.
(P/'plus-texture-gamma.emf').write_bytes(plus([ep(0x4008,texture(flags=0x80),0x100),ep(0x400A,U(0,1)+F(0,0,96,64))]))
# Diagonal antialias coverage mixes premultiplied color, not invisible RGB.
# Left: zero-alpha red cannot stain partially covered opaque blue. Right: two
# unequal nonzero alpha colors exercise the same rule without a zero specialcase.
rs=[ep(0x4008,hatch(2,0x00ff0000,0xff0000ff),0x100),ep(0x400A,U(0,1)+F(8,8,32,40)),ep(0x4008,hatch(2,0x80ff0000,0x400000ff),0x100),ep(0x400A,U(0,1)+F(48,8,32,40))]
(P/'plus-hatch-alpha-edge.emf').write_bytes(plus(rs))

# Original raw indexed/16-bit EMF+ inputs. MS-EMFPLUS 2.2.2.2/3/28,
# PixelFormat2.1.1.24 and PaletteStyle2.1.2.5. No image bytes copied.
# PixelData rows are DWORD-strided. Negative stride stores bottom row first;
# indexed1 consumes MSB first and indexed4 consumes high nibble first.
def raw_bitmap(fmt,width,height,stride,rows,palette=None,palette_flags=0):
 colors=b'' if palette is None else U(palette_flags,len(palette),*palette)
 return U(0xdbc01002,1)+I(width,height,stride)+U(fmt,0)+colors+b''.join(rows if stride>0 else reversed(rows))
def raw_scene(image,width=3,height=2,as_texture=False):
 background=ep(0x400A,U(0xffffffff,1)+F(0,0,96,64),0x8000)
 if as_texture:
  # One clamp tile. Identical source→device mapping to DrawImage below.
  return plus([background,ep(0x4008,texture(wrap=4,transform=(16,0,0,16,4,4),image=image),0x100),ep(0x400A,U(0,1)+F(4,4,width*16,height*16))])
 return plus([background,ep(0x4008,image,0x500),ep(0x401A,U(0xffffffff,2)+F(0,0,width,height)+F(4,4,width*(8 if width==9 else 16),height*16))])
palette_rgb=[0xffffffff,0xffff0000,0xff00ff00,0xff0000ff]
raw_cases={}
for negative in [False,True]:
 suffix='negative' if negative else 'positive'
 raw_cases['indexed1-'+suffix]=(raw_bitmap(0x30101,9,2,-4 if negative else 4,[bytes([0x80,0xff,0xaa,0x55]),bytes([0x7f,0x7f,0x55,0xaa])],[0xff0000ff,0xffff0000]),9,2)
 raw_cases['indexed4-'+suffix]=(raw_bitmap(0x30402,3,2,-4 if negative else 4,[bytes([0x12,0x3f,0xaa,0x55]),bytes([0x32,0x1f,0x55,0xaa])],palette_rgb),3,2)
 palette8=[0xffffffff]*201;palette8[1]=0xffff0000;palette8[2]=0xff00ff00;palette8[200]=0xff0000ff
 raw_cases['indexed8-'+suffix]=(raw_bitmap(0x30803,3,2,-4 if negative else 4,[bytes([1,2,200,255]),bytes([200,2,1,255])],palette8),3,2)
 for fmt,name,top,bottom in [(0x21005,'rgb555',[0xfc00,0x03e0,0x001f],[0x7fff,0,0x7fe0]),(0x21006,'rgb565',[0xf800,0x07e0,0x001f],[0xffff,0,0xffe0]),(0x61007,'argb1555',[0xfc00,0x83e0,0x001f],[0x7c00,0x801f,0xffff])]:
  raw_cases[name+'-'+suffix]=(raw_bitmap(fmt,3,2,-8 if negative else 8,[H(*top)+b'\xaa\x55',H(*bottom)+b'\x55\xaa']),3,2)
raw_cases['indexed-alpha']=(raw_bitmap(0x30402,3,2,4,[bytes([0x12,0x3f,0xaa,0x55]),bytes([0x32,0x1f,0x55,0xaa])],[0xffffffff,0x80ff0000,0xff00ff00,0x000000ff],1),3,2)
raw_cases['indexed-gray']=(raw_bitmap(0x30402,3,2,4,[bytes([0x12,0x3f,0,0]),bytes([0x32,0x1f,0,0])],[0xff000000,0xff555555,0xffaaaaaa,0xffffffff],2),3,2)
raw_cases['indexed-halftone']=(raw_bitmap(0x30402,3,2,4,[bytes([0x12,0x3f,0,0]),bytes([0x32,0x1f,0,0])],palette_rgb,4),3,2)
# Style flags describe the palette; ARGB entry alpha remains real even at0.
raw_cases['indexed-alpha-unflagged']=(raw_bitmap(0x30402,3,2,4,[bytes([0x12,0x3f,0,0]),bytes([0x32,0x1f,0,0])],[0xffffffff,0x80ff0000,0xff00ff00,0x000000ff],0),3,2)
for fmt,name,word in [(0x21005,'rgb555-mid',(3<<10)|(11<<5)|25),(0x21006,'rgb565-mid',(7<<11)|(17<<5)|23)]:
 raw_cases[name]=(raw_bitmap(fmt,3,2,8,[H(word,word,word)+bytes(2)]*2),3,2)
# Compatibility samples intentionally retain sufficient but unaligned24bpp
# stride9. 32bpp RGB ignores its high byte, straight/premultiplied alpha agree.
for negative in [False,True]:
 suffix='negative' if negative else 'positive'
 rows24=[bytes([0,0,255,0,255,0,255,0,0]),bytes([255,255,255,0,0,0,0,255,255])]
 raw_cases['rgb24-'+suffix]=(raw_bitmap(0x21808,3,2,-9 if negative else 9,rows24),3,2)
 rgb32=[bytes([0,0,255,0,0,255,0,0,255,0,0,0]),bytes([255,255,255,0,0,0,0,0,0,255,255,0])]
 raw_cases['rgb32-'+suffix]=(raw_bitmap(0x22009,3,2,-12 if negative else 12,rgb32),3,2)
 for fmt,name,red in [(0x26200a,'argb32',255),(0xe200b,'pargb32',128)]:
  rows=[bytes([0,0,red,128,0,255,0,255,0,0,0,0]),bytes([0,0,0,0,255,0,0,255,255,255,255,255])]
  raw_cases[name+'-'+suffix]=(raw_bitmap(fmt,3,2,-12 if negative else 12,rows),3,2)
for name,(image,width,height) in raw_cases.items():
 (P/('plus-raw-'+name+'.emf')).write_bytes(raw_scene(image,width,height))
# All newly supported bpp families traverse the texture adapter as well.
for name in ['indexed1-positive','indexed4-negative','indexed8-positive','rgb555-negative','rgb565-positive','argb1555-negative','indexed-alpha']:
 image,width,height=raw_cases[name]
 if width==9:
  # Keep one broad 9-pixel clamp tile within the96px canvas.
  rs=[ep(0x400A,U(0xffffffff,1)+F(0,0,96,64),0x8000),ep(0x4008,texture(wrap=4,transform=(8,0,0,16,4,4),image=image),0x100),ep(0x400A,U(0,1)+F(4,4,72,32))]
  payload=plus(rs)
 else:payload=raw_scene(image,width,height,True)
 (P/('plus-raw-texture-'+name+'.emf')).write_bytes(payload)
# Malformed objects retain complete EMF/EMF+ framing. Only the named raw
# contract is wrong; no off-by-one read or white success is acceptable.
base=U(0xdbc01002,1)+I(3,2,4)+U(0x30402,0)
validrows=bytes([0x12,0x3f,0,0,0x32,0x1f,0,0])
raw_bad={
 'palette-flags':base+U(8,4,*palette_rgb)+validrows,
 'palette-zero':base+U(0,0)+validrows,
 'palette-gray':base+U(2,4,*palette_rgb)+validrows,
 'palette-count':base+U(0,17,*([0xffffffff]*17))+validrows,
 'palette-truncated':base+U(0,4,0xffff0000),
 'palette-index':base+U(0,3,*palette_rgb[:3])+validrows,
 'palette-index8':U(0xdbc01002,1)+I(3,2,4)+U(0x30803,0)+U(0,3,*palette_rgb[:3])+bytes([1,2,200,0]*2),
 'indexed-stride':U(0xdbc01002,1)+I(9,2,1)+U(0x30101,0)+U(0,2,0xff0000ff,0xffff0000)+bytes([0x80,0x80]),
 'indexed-unaligned-stride':U(0xdbc01002,1)+I(3,2,3)+U(0x30803,0)+U(0,4,*palette_rgb)+bytes([1,2,3]*2),
 'indexed-truncated':base+U(0,4,*palette_rgb)+validrows[:-1],
 'indexed-trailing':base+U(0,4,*palette_rgb)+validrows+U(0),
 'rgb16-stride':U(0xdbc01002,1)+I(3,2,4)+U(0x21006,0)+H(0xf800,0x07e0,0x001f,0xffff),
 'rgb16-truncated':raw_cases['rgb565-positive'][0][:-1],
 'rgb16-min-stride':U(0xdbc01002,1)+I(3,2,-2147483648)+U(0x21006,0)+bytes(16),
 'raw-size':U(0xdbc01002,1)+I(2147483647,2,4)+U(0x30101,0)+U(0,2,0xffffffff,0xff000000)+bytes(8),
}
for name,image in raw_bad.items():
 (P/('unsupported-raw-'+name+'.emf')).write_bytes(raw_scene(image))
for name in ['palette-flags','palette-index8','rgb16-truncated']:
 (P/('unsupported-raw-texture-'+name+'.emf')).write_bytes(raw_scene(raw_bad[name],as_texture=True))
# Uniform alpha interiors isolate compositing from CoreSVG's interpolation of
# tiny mixed-color source cells. Original mixed fixtures above remain unchanged.
for name,flags in [('indexed-alpha',1),('indexed-alpha-unflagged',0)]:
 image=raw_bitmap(0x30402,8,8,4,[bytes([0x11]*4)]*8,[0xffffffff,0x80ff0000,0xff00ff00,0x000000ff],flags)
 (P/('plus-raw-'+name+'-plateau.emf')).write_bytes(raw_scene(image,8,8))
for negative in [False,True]:
 suffix='negative' if negative else 'positive'
 for fmt,name,red in [(0x26200a,'argb32',255),(0xe200b,'pargb32',128)]:
  image=raw_bitmap(fmt,8,8,-32 if negative else 32,[bytes([0,0,red,128])*8]*8)
  (P/('plus-raw-'+name+'-'+suffix+'-plateau.emf')).write_bytes(raw_scene(image,8,8))

# Original formatted-text records. Field layout and enums follow Microsoft
# MS-EMFPLUS 2.2.1.9/2.2.2.44/2.3.4.14; no glyph/font outlines are embedded.
# https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/9df612d2-fb87-44f7-93fb-0fa0b7b2f276
def string_format(flags=0x1000,align=0,line=0,first=0,tabs=(),tracking=1,trim=0,leading=0,trailing=0,substitution=1,language=0,ranges=(),hotkey=0):
 return U(0xdbc01002,flags,language,align,line,substitution,0)+F(first)+I(hotkey)+F(leading,trailing,tracking)+U(trim)+I(len(tabs),len(ranges))+F(*tabs)+b''.join(I(*r) for r in ranges)
def formatted_text(text='MMMM',fmt=None,rect=(12,12,216,140),size=20,style=0,raw=None,brush=None,transform=None,clip=None,declared_length=None):
 face='Helvetica'.encode('utf-16le');font=U(0xdbc01002)+F(size)+U(2,style,0,len(face)//2)+face
 string=text.encode('utf-16le') if raw is None else raw
 fmt=string_format() if fmt is None else fmt
 # StringFormat is ObjectType7; 2.2.1.9 is the section number, not type9 CustomLineCap.
 rs=[ep(0x400A,U(0xffffffff,1)+F(0,0,240,180),0x8000),ep(0x4008,font,0x601),ep(0x4008,fmt,0x702)]
 if brush is not None:rs.append(ep(0x4008,brush,0x100))
 if clip is not None:rs.append(ep(0x4032,F(*clip)))
 if transform is not None:rs.append(ep(0x402D,F(*transform)))
 rs.append(ep(0x401C,U(0 if brush is not None else 0xff000000,2,len(string)//2 if declared_length is None else declared_length)+F(*rect)+string,1 if brush is not None else 0x8001))
 return plus(rs,240,180)
text_cases={
 'baseline':dict(text='MMMM'),
 # The same native glyph outlines traverse brush paint, world transform and
 # a device clip captured before translation. The brush spans the text run.
 'gradient':dict(text='MMMM',brush=linear(transform=(70,0,0,70,12,12),stops=[(0,0xffff0000),(1,0xff0000ff)])),
 'translated':dict(text='MMMM',transform=(24,36)),
 'translated-clip':dict(text='MMMM',transform=(24,36),clip=(0,0,70,180)),
 'tracking':dict(text='MMMM',fmt=string_format(tracking=1.8)),
 'tab-control':dict(text='HH'),
 'tabs':dict(text='H\tH',fmt=string_format(tabs=(32,32))),
 'tabs-offset':dict(text='H\tH',fmt=string_format(first=12,tabs=(32,32))),
 # Native adaptation: continue the final explicit interval after its last stop.
 # Exact Windows behavior beyond the configured stops remains unproven.
 'tabs-native-continuation':dict(text='H\tH\tH\tH',fmt=string_format(first=12,tabs=(32,))),
 'ranges-metadata':dict(text='MMMM',fmt=string_format(ranges=((0,2),(2,2)))),
 'lcid-bypass':dict(text='MMMM',fmt=string_format(flags=0x80001000,language=0x409)),
 'ltr':dict(text='אבג 123',size=24),
 'rtl':dict(text='אבג 123',fmt=string_format(flags=0x1001),size=24),
 'horizontal':dict(text='ABC',size=24),
 'vertical':dict(text='ABC',fmt=string_format(flags=0x1002),rect=(12,12,180,140),size=24),
 'nowrap':dict(text='ONE TWO THREE FOUR FIVE SIX',rect=(12,12,80,140),size=18),
 'wrap':dict(text='ONE TWO THREE FOUR FIVE SIX',fmt=string_format(flags=0),rect=(12,12,80,140),size=18),
 'line-near':dict(text='LINE',fmt=string_format(line=0),size=18),
 'line-center':dict(text='LINE',fmt=string_format(line=1),size=18),
 'line-far':dict(text='LINE',fmt=string_format(line=2),size=18),
 # Zero extents use the supplied point as alignment anchor, including negative
 # inline/cross offsets; NoClip isolates anchor geometry from rectangle clipping.
 'point-near':dict(text='LINE',fmt=string_format(flags=0x5000),rect=(120,90,0,0),size=18),
 'point-center':dict(text='LINE',fmt=string_format(flags=0x5000,align=1,line=1),rect=(120,90,0,0),size=18),
 'point-far':dict(text='LINE',fmt=string_format(flags=0x5000,align=2,line=2),rect=(120,90,0,0),size=18),
 'short-cross-near':dict(text='LINE',fmt=string_format(flags=0x5000),rect=(120,90,100,6),size=18),
 'short-cross-center':dict(text='LINE',fmt=string_format(flags=0x5000,line=1),rect=(120,90,100,6),size=18),
 'short-cross-far':dict(text='LINE',fmt=string_format(flags=0x5000,line=2),rect=(120,90,100,6),size=18),
 'clip':dict(text='MMMMMMMMMMMM',rect=(12,12,60,40)),
 'no-clip':dict(text='MMMMMMMMMMMM',fmt=string_format(flags=0x5000),rect=(12,12,60,40)),
 'partial-line':dict(text='MMMM',rect=(12,12,100,10)),
 'line-limit':dict(text='MMMM',fmt=string_format(flags=0x3000),rect=(12,12,100,10)),
 'ellipsis':dict(text='MMMMMMMMMMMM',fmt=string_format(trim=3),rect=(12,12,90,40)),
 'path-trim':dict(text='/very/long/directory/report.txt',fmt=string_format(trim=5),rect=(12,12,160,40),size=18),
 'path-tail':dict(text='report.txt',rect=(12,12,160,40),size=18),
 'surrogate-pair':dict(text='A𝐀B',size=24),
 'no-fallback':dict(text='A𝐀B',size=24,fmt=string_format(flags=0x1400)),
 'decorations-control':dict(text='HI HI'),
 'underline':dict(text='HI HI',style=4),
 'strikeout':dict(text='HI HI',style=8),
 'hotkey-plain':dict(text='ABC'),
 'hotkey-display':dict(text='A&BC',fmt=string_format(hotkey=0)),
 'hotkey-show':dict(text='A&BC',fmt=string_format(hotkey=1)),
 'hotkey-hide':dict(text='A&BC',fmt=string_format(hotkey=2)),
 'hotkey-literal':dict(text='A&&BC',fmt=string_format(hotkey=2)),
}
for name,options in text_cases.items():(P/('plus-formatted-'+name+'.emf')).write_bytes(formatted_text(**options))
base_format=string_format()
def change_format(offset,part):return base_format[:offset]+part+base_format[offset+len(part):]
bad_formats={
 'short':base_format[:59], 'trailing':base_format+b'junk',
 'version':change_format(0,U(0)), 'flags':change_format(4,U(0x80)),
 'align':change_format(12,U(3)), 'line-align':change_format(16,U(3)),
 'substitution':change_format(20,U(2)), 'digit-language':change_format(24,U(0x401)), 'display-controls':change_format(4,U(0x20)), 'hotkey':change_format(32,I(99)),
 'first-tab-negative':change_format(28,F(-1)), 'first-tab-nan':change_format(28,F(float('nan'))),
 'leading-negative':change_format(36,F(-1)), 'trailing-infinite':change_format(40,F(float('inf'))),
 'tracking-negative':change_format(44,F(-1)), 'tracking-nan':change_format(44,F(float('nan'))),
 'trimming':change_format(48,U(6)), 'tabs-negative-count':change_format(52,I(-1)),
 'tabs-count':change_format(52,I(1048576)), 'tabs-truncated':change_format(52,I(2))+F(12),
 'tab-negative':string_format(tabs=(-1,)), 'tab-zero':string_format(tabs=(0,)),
 'tab-infinite':string_format(tabs=(float('inf'),)),
 'ranges-negative-count':change_format(56,I(-1)), 'ranges-count':change_format(56,I(1048576)),
 'range-truncated':change_format(56,I(1))+I(0), 'range-negative':string_format(ranges=((-1,2),)), 'range-overflow':string_format(ranges=((2147483647,1),)),
}
for name,fmt in bad_formats.items():(P/('unsupported-formatted-'+name+'.emf')).write_bytes(formatted_text(fmt=fmt))
for name,raw in [('surrogate-high',H(0xd800)),('surrogate-low',H(0xdc00)),('surrogate-order',H(0xdc00,0xd800))]:
 (P/('unsupported-formatted-'+name+'.emf')).write_bytes(formatted_text(raw=raw))

# A complete small draw with an over-budget declared UTF16 count must fail
# before allocating or attempting to substitute missing text.
(P/'unsupported-formatted-text-count.emf').write_bytes(formatted_text(declared_length=262145))

# Full over-budget UTF16 data, not just an impossible declared length.
(P/'unsupported-formatted-text-payload-budget.emf').write_bytes(formatted_text(text='M'*32769))
