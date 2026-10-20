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
pen=U(0xdbc01002,0,0,2)+F(4)+U(0xdbc01002,0,0xffff0000)
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

# Classic GDI clip family. Original records, independently chosen rectangles and
# analytical Boolean pixel oracles; no BaseHmiTypes source/expected SVG is copied.
# RGNDATA is already device-space. Rect/path capture and offsets are logical-space.
CC_A=(8,8,56,48);CC_B=(32,20,80,56)
def cc_region(rects,mode=5):
 bounds=(min(r[0] for r in rects),min(r[1] for r in rects),max(r[2] for r in rects),max(r[3] for r in rects)) if rects else (0,0,0,0)
 payload=U(32,1,len(rects),len(rects)*16)+I(*bounds)+b''.join(I(*r) for r in rects)
 return record(75,U(len(payload),mode)+payload)
def cc_null():return record(75,U(0,5))
def cc_path(rect,mode=5):
 return [record(59),record(43,I(*rect)),record(60),record(67,U(mode))]
def cc_identity():return record(35,F(1,0,0,1,0,0))
def cc_paint():return [brush(1,0xff),selected(1),selected(0x80000008),record(43,I(0,0,96,64))]
def cc_write(name,rs):
 (P/('classic-clip-'+name+'.emf')).write_bytes(emf(rs+cc_paint()))
cc_write('control',[])
for mode,label in [(1,'and'),(2,'or'),(3,'xor'),(4,'diff'),(5,'copy')]:
 cc_write('region-'+label,[cc_region([CC_A]),cc_region([CC_B],mode)])
 cc_write('path-'+label,cc_path(CC_A)+cc_path(CC_B,mode))
 cc_write('empty-'+label,[cc_region([CC_A]),cc_region([],mode)])
cc_write('null-reset',[cc_region([CC_A]),cc_null()])
cc_write('null-reset-mask',[cc_region([CC_A]),cc_region([CC_B],4),cc_null()])
cc_write('region-device',[record(35,F(2,0,0,3,10,7)),cc_region([CC_A]),cc_identity()])
cc_write('region-disjoint',[cc_region([(8,8,24,48),(56,8,80,48)])])
cc_write('region-empty-rectangle',[cc_region([(8,8,8,48)])])
cc_write('rect-intersect',[record(30,I(*CC_A)),record(30,I(*CC_B))])
cc_write('rect-exclude',[record(30,I(*CC_A)),record(29,I(*CC_B))])
cc_write('rect-exclude-default',[record(29,I(*CC_A))])
cc_write('rect-world',[record(35,F(2,0,0,1,10,4)),record(30,I(4,4,20,28)),cc_identity()])
cc_write('rect-map',[record(17,I(8)),record(9,I(48,32)),record(11,I(96,64)),record(12,I(4,6)),record(30,I(4,4,20,20)),record(9,I(96,64)),record(11,I(96,64)),record(12,I(0,0))])
cc_write('path-world',[record(35,F(2,0,0,1,10,4))]+cc_path((4,4,20,28))+[cc_identity()])
# The translation must not contaminate a transformed displacement vector.
cc_write('offset-world',[cc_region([CC_A]),record(35,F(2,0,0,1,10,7)),record(26,I(8,-4)),cc_identity()])
cc_write('offset-offcanvas',[cc_region([(-40,8,-8,48)]),record(26,I(48,0))])
cc_write('offset-none',[record(26,I(20,10))])
cc_write('offset-empty',[cc_region([]),record(26,I(20,10))])
cc_write('meta-selected',[cc_region([CC_A]),record(28),cc_region([CC_B])])
cc_write('meta-null-reset',[cc_region([CC_A]),record(28),cc_null()])
cc_write('meta-offset-selection',[cc_region([CC_A]),record(28),cc_region([CC_B]),record(26,I(-16,-8))])
cc_write('meta-offset-none',[cc_region([CC_A]),record(28),record(26,I(20,10))])
cc_write('meta-repeated',[cc_region([CC_A]),record(28),cc_region([CC_B]),record(28),cc_null()])
cc_write('meta-repeated-no-selection',[cc_region([CC_A]),record(28),record(28),cc_null()])
cc_write('meta-empty',[cc_region([]),record(28),cc_null()])
cc_write('restore-before-meta',[record(33),cc_region([CC_A]),record(28),record(34,I(-1))])
cc_write('restore-meta-and-selection',[cc_region([CC_A]),record(28),cc_region([CC_B]),record(33),record(28),cc_null(),record(34,I(-1))])
cc_write('restore-negative-depth',[cc_region([CC_A]),record(33),cc_region([CC_B]),record(33),record(29,I(40,0,96,64)),record(34,I(-2))])
cc_write('restore-offset',[cc_region([CC_A]),record(33),record(26,I(24,0)),record(34,I(-1))])
# Region/offset/meta operations must leave a selected path available to FillPath.
# Paint only the selected path: appending cc_paint's full rectangle would mask bugs.
for name,ops,expected in [
 ('path-preserved-region',[cc_region([CC_A])],None),
 ('path-preserved-meta',[cc_region([CC_A]),record(28)],None),
 ('path-preserved-offset',[cc_region([CC_A]),record(26,I(8,0))],None)]:
 rs=[brush(1,0xff),selected(1),selected(0x80000008),record(59),record(43,I(*CC_B)),record(60)]+ops+[record(62,I(0,0,96,64))]
 (P/('classic-clip-'+name+'.emf')).write_bytes(emf(rs))
# Bad clips must refuse the image rather than retain an earlier clip and produce
# a plausible successful raster. Each malformed fixture has a valid outer chain.
def cc_bad(name,rs):
 (P/('unsupported-classic-clip-'+name+'.emf')).write_bytes(emf(rs+cc_paint()))
base_region=cc_region([CC_A])
def cc_changed(raw,offset,part):return raw[:offset]+part+raw[offset+len(part):]
for name,offset,value in [
 ('region-size-small',8,31),('region-size-large',8,64),
 ('region-mode-zero',12,0),('region-mode-six',12,6),
 ('region-header-size',16,36),('region-type',20,2),
 ('region-count',24,0xffffffff),('region-buffer-size',28,15)]:
 cc_bad(name,[cc_changed(base_region,offset,U(value))])
cc_bad('region-reversed',[cc_region([(24,8,8,48)])])
cc_bad('region-truncated',[record(75,U(48,5)+base_region[16:-4])])
cc_bad('region-trailing',[record(75,base_region[8:]+U(0))])
for mode in [0,1,2,3,4,6]:cc_bad('null-mode-'+str(mode),[record(75,U(0,mode))])
cc_bad('null-trailing',[record(75,U(0,5,0))])
cc_bad('region-short',[record(75,U(48))])
for mode in [0,6]:cc_bad('path-mode-'+str(mode),cc_path(CC_A,mode))
cc_bad('path-missing',[record(67,U(5))])
cc_bad('path-short',cc_path(CC_A)[:-1]+[record(67)])
cc_bad('rect-short',[record(30,I(8,8,56))])
cc_bad('offset-short',[record(26,I(8))])
cc_bad('restore-unmatched',[record(34,I(-1))])
cc_bad('restore-depth',[record(33),record(34,I(-2))])
cc_write('restore-absolute-one',[cc_region([CC_A]),record(33),cc_region([CC_B]),record(33),record(29,I(40,0,96,64)),record(34,I(1))])
cc_write('restore-absolute-two',[cc_region([CC_A]),record(33),cc_region([CC_B]),record(33),record(29,I(40,0,96,64)),record(34,I(2))])
# Frame origin shifts initially recorded device geometry, while subsequent world
# changes cannot move a captured RGNDATA clip. Frame rounding is <0.03pixel.
frame=bytearray(emf([cc_region([CC_A])]+cc_paint()))
frame[24:40]=I(*(round(v*2540/96) for v in (8,4,104,68)))
(P/'classic-clip-region-frame-origin.emf').write_bytes(frame)
cc_bad('path-consumed',cc_path(CC_A)+[record(67,U(5))])
cc_bad('restore-absolute-missing',[record(33),record(34,I(2))])
for mode,label in [(1,'and'),(2,'or'),(3,'xor'),(4,'diff'),(5,'copy')]:
 cc_write('default-'+label,[cc_region([CC_A],mode)])
cc_write('rect-shear',[record(35,F(1,0,.5,1,0,0)),record(30,I(8,8,40,40)),cc_identity()])
cc_write('offset-mask',[cc_region([CC_A]),cc_region([CC_B],3),record(26,I(8,0))])
cc_write('path-offcanvas-offset',cc_path((-40,8,-8,48))+[record(26,I(48,0))])
for rule,label in [(1,'evenodd'),(2,'nonzero')]:
 cc_write('path-'+label,[record(19,U(rule)),record(59),record(43,I(*CC_A)),record(43,I(20,20,44,36)),record(60),record(67,U(5))])
# Win32 RGNDATAHEADER permits nRgnSize0 when the region-buffer size is unknown;
# actual count/framing still identifies precisely one complete rectangle.
cc_write('region-unknown-size',[cc_changed(base_region,28,U(0))])
cc_bad('offset-domain-budget',[cc_region([CC_A]),record(26,I(1000001,0))])

cc_bad('offset-domain-area-budget',[cc_region([CC_A]),record(26,I(20000,20000))])
# GetDC supplies temporary classic GDI state. A later EMF+ record closes that
# interval; a second GetDC cannot inherit its selected clip or metaregion.
for label,ops in [('selected',[cc_region([CC_A])]),('meta',[cc_region([CC_A]),record(28)])]:
 rs=[comment([ep(0x4001,U(0xdbc01002,1,96,96),1),ep(0x4004)])]+ops+cc_paint()
 rs += [comment([ep(0x402B),ep(0x4004)]),brush(2,0xff00),selected(2),selected(0x80000008),record(43,I(*CC_B)),comment([ep(0x4002)])]
 (P/('classic-clip-getdc-'+label+'.emf')).write_bytes(emf(rs))

# EMF+ pens: PenDataOptional fields follow increasing flag order; BrushObject
# is a complete versioned EmfPlusBrush, not just BrushType+ARGB. This matches
# MS-EMFPLUS 2.2.1.7 and its independent 3.2.33.1 serialized pen example.
PV=0xdbc01002
def pp_pen(width=8,unit=2,transform=None,start=None,end=None,join=None,miter=None,style=None,dashcap=None,offset=None,pattern=None,align=None,compound=None,brush=None,customStart=None,customEnd=None):
 bits=0;optional=b''
 for bit,value,encode in [
  (1,transform,lambda a:F(*a)),(2,start,U),(4,end,U),(8,join,U),
  (16,miter,F),(32,style,U),(64,dashcap,U),(128,offset,F),
  (256,pattern,lambda a:U(len(a))+F(*a)),(512,align,U),
  (1024,compound,lambda a:U(len(a))+F(*a)),
  (2048,customStart,lambda a:U(len(a))+a),(4096,customEnd,lambda a:U(len(a))+a)]:
  if value is not None:bits|=bit;optional+=encode(value)
 return U(PV,0,bits,unit)+F(width)+optional+(U(PV,0,0xffff0000) if brush is None else brush)
def pp_lines(points=((20,32),(76,32)),id=0,closed=False):
 return ep(0x400D,U(len(points))+F(*(v for p in points for v in p)),id|(0x2000 if closed else 0))
def pp_rect(rect=(20,16,56,32),id=0):return ep(0x400B,U(1)+F(*rect),id)
def pp_write(name,pen=None,draw=None,prefix=None,extra=None):
 rs=list(prefix or [])+[ep(0x4008,pp_pen() if pen is None else pen,0x200),pp_lines() if draw is None else draw]+list(extra or [])
 (P/('plus-pen-'+name+'.emf')).write_bytes(plus(rs))
def pp_bad(name,pen,draw=None):
 (P/('unsupported-pen-'+name+'.emf')).write_bytes(plus([ep(0x4008,pen,0x200),pp_lines() if draw is None else draw]))
pp_write('flat')
pp_write('vertical',draw=pp_lines(((48,12),(48,52))))
pp_write('diagonal',draw=pp_lines(((20,16),(76,48))))
pp_write('width-zero',pen=pp_pen(width=0))
pp_write('width-one',pen=pp_pen(width=1))
for cap,name in [(0,'flat'),(1,'square'),(2,'round'),(3,'triangle'),(16,'no-anchor'),(17,'square-anchor'),(18,'round-anchor'),(19,'diamond-anchor'),(20,'arrow-anchor')]:
 pp_write('end-'+name,pen=pp_pen(end=cap))
 pp_write('start-'+name,pen=pp_pen(start=cap))
pp_write('asymmetric-caps',pen=pp_pen(start=1,end=2))
pp_write('round-triangle',pen=pp_pen(start=2,end=3))
pp_write('compound',pen=pp_pen(width=20,compound=[0,.15,.25,.5,.7,1]))
pp_write('compound-asymmetric',pen=pp_pen(width=20,compound=[0,.2,.45,.75]))
pp_write('compound-reversed',pen=pp_pen(width=20,compound=[0,.2,.45,.75]),draw=pp_lines(((76,32),(20,32))))
pp_write('compound-closed',pen=pp_pen(width=16,compound=[0,.25,.75,1]),draw=pp_rect())
pp_write('center',draw=pp_rect())
pp_write('inset',pen=pp_pen(align=1),draw=pp_rect())
pp_write('open-inset',pen=pp_pen(align=1))
pp_write('transform',pen=pp_pen(transform=(2,0,0,3,0,0)))
pp_write('transform-translation',pen=pp_pen(transform=(2,0,0,3,13,-9)))
pp_write('transform-shear',pen=pp_pen(transform=(1,0,1,1,0,0)))
pp_write('transform-caps',pen=pp_pen(transform=(2,0,0,3,0,0),start=1,end=2))
pp_write('world-clip',pen=pp_pen(transform=(2,0,0,3,0,0)),draw=pp_lines(((16,24),(72,24))),prefix=[ep(0x4032,F(12,12,64,40)),ep(0x402D,F(8,8))])
for style,name in [(0,'solid'),(1,'dash'),(2,'dot'),(3,'dash-dot'),(4,'dash-dot-dot')]:
 pp_write('style-'+name,pen=pp_pen(width=4,style=style))
pp_write('dash-offset',pen=pp_pen(width=4,style=1,offset=1))
pp_write('dash-negative-offset',pen=pp_pen(width=4,style=1,offset=-1))
pp_write('dash-custom',pen=pp_pen(width=4,style=5,pattern=[2,1]))
pp_write('dash-odd',pen=pp_pen(width=4,style=5,pattern=[2,1,1]))
pp_write('dash-round',pen=pp_pen(width=4,style=1,dashcap=2))
pp_write('dash-triangle',pen=pp_pen(width=4,style=1,dashcap=3))
pp_write('dash-round-line-caps',pen=pp_pen(width=4,style=1,dashcap=2,start=1,end=3))
v=((24,48),(48,12),(72,48))
for join,name,limit in [(0,'miter',10),(0,'miter-limited',1.6),(1,'bevel',10),(2,'round',10),(3,'miter-clipped',1.6)]:
 pp_write('join-'+name,pen=pp_pen(join=join,miter=limit),draw=pp_lines(v))
 pp_write('join-'+name+'-reversed',pen=pp_pen(join=join,miter=limit),draw=pp_lines(v[::-1]))
# The path and primitive entry points share the same pen outline contract.
path=U(PV,2,0)+F(20,32,76,32)+pad(bytes([0,1]))
pp_write('path',prefix=[ep(0x4008,path,0x301)],draw=ep(0x4015,U(0),1))
pp_write('ellipse',pen=pp_pen(width=4),draw=ep(0x400F,F(20,12,56,40)))
pp_write('arc',pen=pp_pen(width=4),draw=ep(0x4012,F(0,180,20,12,56,40)))
pp_write('bezier',pen=pp_pen(width=6),draw=ep(0x4019,U(4)+F(20,32,36,8,60,56,76,32)))
# Brush controls paint the same known horizontal rectangle without any pen.
for name,brush_data in [('hatch',hatch(0)),('gradient',linear(wrap=4,transform=(64,0,0,16,16,24),stops=[(0,0xffff0000),(1,0xff0000ff)])),('texture',texture(transform=(16,0,0,8,16,24)))]:
 pp_write(name,pen=pp_pen(width=16,brush=brush_data),draw=pp_lines(((16,32),(80,32))))
 rs=[ep(0x4008,brush_data,0x100),ep(0x400A,U(0,1)+F(16,24,64,16))]
 (P/('plus-pen-'+name+'-control.emf')).write_bytes(plus(rs))
# Different pen brush objects must not leak paint into the next pen or fill.
rs=[ep(0x4008,pp_pen(brush=hatch(0)),0x200),ep(0x4008,pp_pen(width=8,brush=U(PV,0,0xff0000ff)),0x201),pp_lines(((16,16),(80,16))),pp_lines(((16,32),(80,32)),id=1),ep(0x400A,U(0xff00ff00,1)+F(16,44,64,12),0x8000)]
(P/'plus-pen-brush-ownership.emf').write_bytes(plus(rs))
# Refusals retain a complete valid outer record chain. Mutations isolate one
# field, avoiding misleading passes caused by unrelated EMF framing failures.
base=pp_pen()
def pp_changed(raw,offset,part):return raw[:offset]+part+raw[offset+len(part):]
for name,offset,value in [('version',0,0xdeadbeef),('type',4,1),('flags',8,0x80000000),('unit',12,7),('brush-version',20,0xdeadbeef),('brush-type',24,5)]:pp_bad(name,pp_changed(base,offset,U(value)))
for name,width in [('width-negative',-1),('width-nan',float('nan')),('width-infinite',float('inf'))]:pp_bad(name,pp_pen(width=width))
pp_bad('truncated-header',base[:16])
pp_bad('truncated-brush',base[:-1])
pp_bad('trailing-brush',base+U(0))
pp_bad('legacy-unversioned-brush',base[:20]+base[24:])
pp_bad('transform-truncated',pp_pen(transform=(1,0,0,1,0,0))[:36])
pp_bad('transform-singular',pp_pen(transform=(1,0,0,0,0,0)))
pp_bad('transform-nan',pp_pen(transform=(1,0,0,float('nan'),0,0)))
pp_bad('start-cap',pp_pen(start=4))
pp_bad('end-cap',pp_pen(end=255))
pp_bad('join',pp_pen(join=4))
pp_bad('miter-nan',pp_pen(miter=float('nan')))
pp_bad('miter-negative',pp_pen(miter=-1))
pp_bad('dash-style',pp_pen(style=6))
pp_bad('dash-cap',pp_pen(style=1,dashcap=1))
pp_bad('dash-offset',pp_pen(style=1,offset=float('nan')))
pp_bad('dash-custom-missing',pp_pen(style=5))
for name,array in [('empty',[]),('negative',[2,-1]),('zero',[2,0]),('nan',[2,float('nan')])]:pp_bad('dash-pattern-'+name,pp_pen(style=5,pattern=array))
pp_bad('dash-pattern-count',pp_changed(pp_pen(style=5,pattern=[2,1]),24,U(10001)))
pp_bad('dash-pattern-truncated',pp_pen(style=5,pattern=[2,1])[:-8])
pp_bad('alignment',pp_pen(align=2))
for name,array in [('single',[0]),('odd',[0,.5,1]),('descending',[0,.75,.5,1]),('duplicate',[0,.5,.5,1]),('negative',[-.1,.5]),('above-one',[0,1.1]),('nan',[0,float('nan')])]:pp_bad('compound-'+name,pp_pen(compound=array))
pp_bad('compound-count',pp_changed(pp_pen(compound=[0,1]),20,U(10001)))
pp_bad('compound-truncated',pp_pen(compound=[0,1])[:-8])
pp_bad('inset-compound',pp_pen(align=1,compound=[0,.25,.75,1]))
pp_bad('inset-triangle-dash',pp_pen(align=1,style=1,dashcap=3))
pp_bad('custom-start-cap',pp_changed(base,8,U(0x800)))
pp_bad('custom-end-cap',pp_changed(base,8,U(0x1000)))
pp_bad('hatch-style',pp_pen(brush=hatch(53)))
pp_bad('texture-image',pp_pen(brush=texture(image=texture_raw[:-5])))
# DrawClosedCurve has relative signed integer points when P is set; C is then
# ignored. Nonzero alignment bytes are ordinary framing padding, not coordinates.
closed_points=((20,16),(76,16),(48,48))
closed_relative=b''.join(relative_scalar(v) for v in (20,16,56,0,-28,32))+bytes([0xa5,0x5a])
pp_write('closed-curve-relative',draw=ep(0x4017,F(0)+U(3)+closed_relative,0x0800))
pp_write('closed-curve-relative-c',draw=ep(0x4017,F(0)+U(3)+closed_relative,0x4800))
pp_write('closed-curve-control',draw=ep(0x4017,F(0)+U(3)+F(*(v for p in closed_points for v in p))))
pp_bad('closed-curve-two-points',pp_pen(),draw=ep(0x4017,F(0)+U(2)+F(20,16,76,16)))
# World pen units are already page units; physical units convert through page
# unit DPI before the independent page scale. Point-page scale3 is exactly4px.
page=[ep(0x4030,F(3),3)]
page_line=pp_lines(((5,8),(19,8)))
pp_write('unit-world-page',pen=pp_pen(width=2,unit=0),draw=page_line,prefix=page)
pp_write('unit-pixel-page',pen=pp_pen(width=2,unit=2),draw=page_line,prefix=page)
pp_write('unit-point-page',pen=pp_pen(width=2,unit=3),draw=page_line,prefix=page)
pp_write('unit-inch-page',pen=pp_pen(width=1/12,unit=4),draw=page_line,prefix=page)
# A zero-width pen is a device hairline, not a one-page-unit stroke that grows
# when the world scales. All centerline coordinates remain exact integers.
pp_write('hairline-world',pen=pp_pen(width=0),draw=pp_lines(((10,16),(38,16))),prefix=[ep(0x402A,F(2,0,0,2,0,0))])
# Offset+NumSegments draws only the middle two cardinal spans; unused initial
# and final points must not become visible. Tension0 has independent straight
# segment geometry, so the baseline horizontal stroke is its pixel oracle.
curve_points=((4,4),(20,32),(48,32),(76,32),(92,56))
pp_write('curve-range',draw=ep(0x4018,F(0)+U(1,2,5)+F(*(v for p in curve_points for v in p))))
pp_write('curve-range-compressed',draw=ep(0x4018,F(0)+U(1,2,5)+struct.pack('<10h',*(v for p in curve_points for v in p)),0x4000))
pp_write('lines-compressed',draw=ep(0x400D,U(2)+struct.pack('<4h',20,32,76,32),0x4000))
pp_write('lines-relative',draw=ep(0x400D,U(2)+b''.join(relative_scalar(v) for v in (20,32,56,0)),0x0800))
pp_write('lines-closed',draw=pp_lines(((20,16),(76,16),(76,48),(20,48)),closed=True))
pp_write('rect-compressed',draw=ep(0x400B,U(1)+struct.pack('<4h',20,16,56,32),0x4000))
pp_write('ellipse-compressed',pen=pp_pen(width=4),draw=ep(0x400F,struct.pack('<4h',20,12,56,40),0x4000))
pp_write('bezier-compressed',pen=pp_pen(width=6),draw=ep(0x4019,U(4)+struct.pack('<8h',20,32,36,8,60,56,76,32),0x4000))
pp_bad('curve-offset',pp_pen(),draw=ep(0x4018,F(0)+U(5,1,5)+F(*(v for p in curve_points for v in p))))
pp_bad('curve-segment-count',pp_pen(),draw=ep(0x4018,F(0)+U(1,4,5)+F(*(v for p in curve_points for v in p))))
pp_bad('curve-zero-segments',pp_pen(),draw=ep(0x4018,F(0)+U(1,0,5)+F(*(v for p in curve_points for v in p))))
pp_bad('curve-negative-tension',pp_pen(),draw=ep(0x4018,F(-1)+U(1,2,5)+F(*(v for p in curve_points for v in p))))
pp_bad('lines-one-point',pp_pen(),draw=ep(0x400D,U(1)+F(20,32)))
pp_bad('lines-truncated',pp_pen(),draw=ep(0x400D,U(3)+F(20,32,76,32)))
pp_bad('lines-relative-truncated',pp_pen(),draw=ep(0x400D,U(2)+bytes([0x80]),0x0800))
# A collinear cubic reverses direction twice outside its endpoint interval.
# The derivative roots are about0.176/0.824, with extrema near31.15/64.85;
# testing only distance to the infinite chord would incorrectly drop this ink.
pp_write('bezier-backtrack',draw=ep(0x4019,U(4)+F(40,32,4,32,92,32,56,32)))
# Inset doubles the geometric outline width before intersecting with its fill,
# but dash lengths and phase remain based on the ORIGINAL8-unit pen width.
pp_write('inset-dash',pen=pp_pen(align=1,style=1),draw=pp_rect())
pp_write('inset-dash-offset',pen=pp_pen(align=1,style=1,offset=1),draw=pp_rect())

# Complete custom caps (MS-EMFPLUS 2.2.1.2 / 2.2.2.12–14). Embedded caps
# include Version+Type; nested paths include Version and an independent size.
def pc_path(points,types=None,flags=0,padding=b''):
 if types is None:
  types=([0]+[1]*(len(points)-1)) if points else []
  if types:types[-1]|=128
 if flags&0x800:
  previous=(0,0);coordinates=b''
  for point in points:
   coordinates+=b''.join(relative_scalar(point[i]-previous[i]) for i in range(2));previous=point
 elif flags&0x4000:coordinates=struct.pack('<'+'h'*(2*len(points)),*(v for pt in points for v in pt))
 else:coordinates=F(*(v for pt in points for v in pt))
 if flags&0x800:
  encoded=b'';i=0
  while i<len(types):
   n=1
   while i+n<len(types) and types[i+n]==types[i] and n<63:n+=1
   encoded+=bytes((0x40|(0x80 if types[i]&15==3 else 0)|n,types[i]));i+=n
 else:encoded=bytes(types)
 return U(PV,len(points),flags)+coordinates+encoded+padding
def pc_default(fill=None,stroke=None,base=0,inset=0,start=0,end=0,join=0,miter=10,scale=1,hotspot=(0,0,0,0)):
 flags=(1 if fill is not None else 0)|(2 if stroke is not None else 0)
 paths=b''.join(I(len(path))+path for path in (fill,stroke) if path is not None)
 return U(PV,0,flags,base)+F(inset)+U(start,end,join)+F(miter,scale,*hotspot)+paths
def pc_arrow(width=3,height=4,middle=0,filled=1,start=0,end=0,join=0,miter=10,scale=1,hotspot=(0,0,0,0)):
 return U(PV,1)+F(width,height,middle)+U(filled,start,end,join)+F(miter,scale,*hotspot)
def pc_write(name,cap=None,startcap=None,width=4,draw=None,**kwargs):
 pp_write('custom-'+name,pen=pp_pen(width=width,end=255 if cap is not None else None,start=255 if startcap is not None else None,customEnd=cap,customStart=startcap,**kwargs),draw=draw)
def pc_bad(name,cap):pp_bad('custom-'+name,pp_pen(width=4,end=255,customEnd=cap))
# Cap-local +Y is outward along the endpoint tangent, +X is -normal.
# The rectangle lies wholly beyond the tip: horizontal terminal ink spans
# x76..88 and y24..40 at penwidth4. Controls can use this independent box.
pc_box=pc_path(((-2,0),(2,0),(2,3),(-2,3)))
pc_hollow=pc_path(((-2,-3),(2,-3),(2,1),(-2,1)))
pc_triangle=pc_path(((-2,-3),(0,0),(2,-3)))
pc_curve=pc_path(((-2,0),(-2,3),(2,3),(2,0)),[0,3,3,131])
pc_write('fill',cap=pc_default(fill=pc_box))
pc_write('stroke',cap=pc_default(stroke=pc_hollow))
pc_write('both-paths',cap=pc_default(fill=pc_box,stroke=pc_hollow))
pc_write('curve',cap=pc_default(fill=pc_curve))
pc_write('start',startcap=pc_default(fill=pc_box))
pc_write('both-ends',cap=pc_default(fill=pc_box),startcap=pc_default(fill=pc_triangle))
pc_write('vertical',cap=pc_default(fill=pc_box),draw=pp_lines(((48,12),(48,40))))
pc_write('diagonal',cap=pc_default(fill=pc_box),draw=pp_lines(((20,16),(60,40))))
pc_write('reversed',cap=pc_default(fill=pc_box),draw=pp_lines(((76,32),(20,32))))
pc_write('width-scale',cap=pc_default(fill=pc_box,scale=2))
pc_write('inset',cap=pc_default(stroke=pc_hollow,inset=2))
pc_write('negative-inset',cap=pc_default(stroke=pc_hollow,inset=-2))
pc_write('base-round',cap=pc_default(base=2))
pc_write('empty-path',cap=pc_default(fill=pc_path((),[])))
pc_write('scale-zero',cap=pc_default(fill=pc_box,scale=0))
pc_write('short',cap=pc_default(fill=pc_path(((-2,0),(2,0),(2,3),(-2,3)),flags=0x4000)))
pc_write('relative',cap=pc_default(fill=pc_path(((-2,0),(2,0),(2,3),(-2,3)),flags=0x800)))
pc_write('relative-c',cap=pc_default(fill=pc_path(((-2,0),(2,0),(2,3),(-2,3)),flags=0x4800)))
pc_write('rle',cap=pc_default(fill=pc_path(((-2,0),(2,0),(2,3),(-2,3)),flags=0x800)))
# Five float points include the redundant explicit closing vertex: meaningful
# size57 requires three ignored nonzero alignment bytes, making pathsize60.
pc_write('padding',cap=pc_default(fill=pc_path(((-2,0),(2,0),(2,3),(-2,3),(-2,0)),padding=b'\xa5\x5a\xe7'))+b'\x99')
# Same-direction nested contours must use winding even with alternate flag0.
nested=((-3,0),(3,0),(3,4),(-3,4),(-1,1),(1,1),(1,3),(-1,3))
pc_write('winding',cap=pc_default(fill=pc_path(nested,[0,1,1,129,0,1,1,129])))
for name,kwargs in [('filled',{}),('notch',{'middle':2}),('diamond',{'middle':-2}),('invisible',{'middle':4}),('outline',{'filled':0}),('outline-middle',{'filled':0,'middle':3}),('scaled',{'scale':2}),('zero-width',{'width':0}),('zero-height',{'height':0})]:pc_write('arrow-'+name,cap=pc_arrow(**kwargs))
pc_write('arrow-start',startcap=pc_arrow())
pc_write('arrow-asymmetric',cap=pc_arrow(),startcap=pc_default(fill=pc_box))
pc_write('compound',cap=pc_default(fill=pc_box),width=8,compound=[0,.25,.75,1])
pc_write('dash',cap=pc_default(fill=pc_box),style=1,dashcap=2)
pc_write('closed',cap=pc_default(fill=pc_box),startcap=pc_arrow(),draw=pp_rect())
pc_write('transform',cap=pc_default(fill=pc_box),transform=(1,0,.5,1,0,0))
pc_write('transform-translation',cap=pc_default(fill=pc_box),transform=(1,0,.5,1,13,-9))
pp_write('custom-world-clip',pen=pp_pen(width=4,end=255,customEnd=pc_default(fill=pc_box)),prefix=[ep(0x4032,F(12,12,72,40)),ep(0x402A,F(1,0,0,1,4,0))])
for name,brush_data in [('hatch',hatch(0)),('gradient',linear(wrap=4,transform=(64,0,0,16,16,24),stops=[(0,0xffff0000),(1,0xff0000ff)])),('texture',texture(transform=(16,0,0,8,16,24)))]:pc_write(name,cap=pc_default(fill=pc_box),brush=brush_data)
# The complete standalone ObjectType9 cap is legal but does not draw itself;
# embedded Pen custom caps are complete data, never references to its ID.
pp_write('custom-object',extra=[ep(0x4008,pc_default(fill=pc_box),0x903)])
pp_write('custom-inactive',pen=pp_pen(width=4,customEnd=pc_default(fill=pc_box)))
# All refusals preserve valid outer record/pen/brush framing.
validcap=pc_default(fill=pc_box)
for name,offset,value in [('version',0,0xdeadbeef),('type',4,2),('flags',8,4),('base-cap',12,255),('stroke-start',20,16),('stroke-end',24,255),('join',28,4),('path-length-negative',56,0xffffffff),('path-length-large',56,0x7fffffff),('path-version',60,0xdeadbeef),('path-count',64,65537),('path-flags',68,2)]:pc_bad(name,pp_changed(validcap,offset,U(value)))
for name,offset,value in [('inset-nan',16,float('nan')),('miter-nan',32,float('nan')),('miter-zero',32,0),('scale-negative',36,-1),('scale-infinite',36,float('inf')),('path-coordinate',72,float('nan'))]:pc_bad(name,pp_changed(validcap,offset,F(value)))
pc_bad('truncated',validcap[:-5]);pc_bad('trailing',validcap+U(0));pc_bad('path-trailing',pc_default(fill=pc_box+U(0)))
pc_bad('path-first-line',pc_default(fill=pc_path(((0,0),(1,1)),[1,1])))
pc_bad('path-cubic-count',pc_default(stroke=pc_path(((0,0),(1,1),(2,0)),[0,3,3])))
pc_bad('path-cubic-close',pc_default(stroke=pc_path(((0,0),(1,1),(2,1),(3,0)),[0,131,3,3])))
pc_bad('path-type-reserved',pc_default(fill=pc_path(((0,0),(1,1)),[0,0x41])))
pc_bad('path-relative-truncated',pc_default(fill=U(PV,1,0x800)+b'\x80'))
pc_bad('path-rle-zero',pc_default(fill=U(PV,1,0x800)+bytes((0,0,0x40,0))))
pc_bad('path-rle-overrun',pc_default(fill=U(PV,1,0x800)+bytes((0,0,0x42,0))))
for name,kwargs in [('fill-state',{'filled':2}),('negative-width',{'width':-1}),('negative-height',{'height':-1}),('middle-nan',{'middle':float('nan')}),('scale-negative',{'scale':-1})]:pc_bad('arrow-'+name,pc_arrow(**kwargs))
# A legal cap with an impossible requested body trim is refused rather than
# inventing the undefined GDI+ behavior of BaseInset beyond the line length.
pc_write('short-line',cap=pc_default(fill=pc_box,inset=1),draw=pp_lines(((40,32),(44,32))))
pp_bad('custom-overlong-inset',pp_pen(width=4,end=255,customEnd=pc_default(fill=pc_box,inset=100)))

# Cap-local outlines retain their own cap/join/miter choices, independent of the
# shaft pen; the open chevron makes the four styles visibly distinguishable.
pc_open=pc_path(((-2,-3),(0,0),(2,-3)),[0,1,1])
for style in range(4):pc_write('stroke-style-'+str(style),cap=pc_default(stroke=pc_open,start=style,end=style,join=style,miter=1.6))
# An ordinary Path containing two open figures must attach caps once to each
# physical figure, while a closed figure receives neither endpoint custom cap.
body_multi=pc_path(((12,16),(48,16),(12,48),(48,48)),[0,1,0,1])
pp_write('custom-multiple-figures',pen=pp_pen(width=4,end=255,customEnd=pc_default(fill=pc_box)),prefix=[ep(0x4008,body_multi,0x301)],draw=ep(0x4015,U(0),1))
# Inset on an open physical path still uses centered shaft geometry, and caps
# remain endpoint adornments instead of becoming a closed-path inset region.
pc_write('open-inset',cap=pc_default(fill=pc_box),align=1)
pc_write('closed-inset',cap=pc_default(fill=pc_box),align=1,draw=pp_rect())
# Object-level cap framing errors are rejected even if never used by a pen.
for name,raw in [('object-type',U(PV,2)),('object-truncated',validcap[:-5])]:
 (P/('unsupported-pen-custom-'+name+'.emf')).write_bytes(plus([ep(0x4008,raw,0x903)]))

# The Path R flag couples relative coordinates and type RLE; the similarly
# named DrawLines relative flag must not justify an independent Path RLE flag.
pc_bad('path-rle-marker',pc_default(fill=U(PV,1,0x800)+bytes((0,0,1,0))))
pc_bad('path-rle-bezier-kind',pc_default(fill=U(PV,1,0x800)+bytes((0,0,0xc1,0))))
pc_bad('path-rle-reserved-flag',pc_default(fill=U(PV,1,0x1000)+F(0,0)+bytes((1,0))))

pc_write('curve-relative',cap=pc_default(fill=pc_path(((-2,0),(-2,3),(2,3),(2,0)),[0,3,3,131],flags=0x800)))

# Independent brush controls use two ordinary rectangles for shaft+outward box;
# they never call the custom cap parser or native stroke outline builder.
for name,brush_data in [('hatch',hatch(0)),('gradient',linear(wrap=4,transform=(64,0,0,16,16,24),stops=[(0,0xffff0000),(1,0xff0000ff)])),('texture',texture(transform=(16,0,0,8,16,24)))]:
 rs=[ep(0x4008,brush_data,0x100),ep(0x400A,U(0,2)+F(20,30,56,4,76,24,12,16))]
 (P/('plus-pen-custom-'+name+'-control.emf')).write_bytes(plus(rs))

# Hotspots are unused by playback, including arbitrary nonfinite bit patterns.
pc_write('hotspot-ignored',cap=pc_default(fill=pc_box,hotspot=(1,float('nan'),float('inf'),-1)))
pc_write('arrow-hotspot-ignored',cap=pc_arrow(hotspot=(1,float('nan'),float('inf'),-1)))
# Opposite-winding cap holes must not subtract ink from the independent shaft.
# Device outer box64..80×20..44, hole68..76×28..36 crosses shafty30..34.
pc_hole=pc_path(((-3,-3),(3,-3),(3,1),(-3,1),(-1,-2),(-1,0),(1,0),(1,-2)),[0,1,1,129,0,1,1,129])
pc_write('winding-hole-shaft',cap=pc_default(fill=pc_hole))

# Shared EmfPlusPath grammar (MS-EMFPLUS 2.2.1.6, 2.2.2.21/.22/.32/.37).
# These are original integer geometries with independent float counterparts.
# R=0x0800 couples signed PointR coordinates and type RLE; C=0x4000 is
# ignored when R is present. There is no Path fill-mode bit in this wire object.
def cp_path(points,types=None,flags=0,padding=True):
 raw=pc_path(points,types,flags)
 return raw+(bytes((0xa5,0x5a,0xe7))[:(-len(raw))%4] if padding else b'')
def cp_write(name,records):
 (P/('plus-compressed-path-'+name+'.emf')).write_bytes(plus(records))
def cp_object(raw,id=1):return ep(0x4008,raw,0x300|id)
def cp_fill(raw):return [cp_object(raw),ep(0x4014,U(0xffff0000),0x8001)]
def cp_region(raw):return [region_object((U(0x10000001,len(raw))+raw,1)),region_fill()]
def cp_cap(raw):
 return [ep(0x4008,pp_pen(width=4,end=255,customEnd=pc_default(fill=raw)),0x200),pp_lines()]
cp_ring=((8,8),(88,8),(88,56),(8,56),(24,20),(72,20),(72,44),(24,44))
cp_ring_types=[0,1,1,129,0,1,1,129]
cp_curve=((8,48),(8,8),(48,8),(48,48),(64,48),(88,48))
cp_curve_types=[0,3,3,3,0,1]
cp_rectangle=((8,12),(72,12),(72,52),(8,52))
cp_cap_points=((-2,0),(2,0),(2,3),(-2,3))
for encoding,flags in [('float',0),('short',0x4000),('relative',0x0800),('relative-c',0x4800)]:
 raw=cp_path(cp_ring,cp_ring_types,flags)
 cp_write('fill-'+encoding,cp_fill(raw))
 cp_write('region-'+encoding,cp_region(raw))
 cp_write('stroke-'+encoding,[cp_object(cp_path(cp_curve,cp_curve_types,flags)),ep(0x4008,pp_pen(width=4),0x200),ep(0x4015,U(0),1)])
 # Captured clip is translated eight pixels, then world transform is reset.
 cp_write('clip-'+encoding,[cp_object(cp_path(cp_rectangle,flags=flags)),ep(0x402D,F(8,0)),ep(0x4033,flags=1),ep(0x402B),ep(0x400A,U(0xffff0000,1)+F(0,0,96,64),0x8000)])
 cp_write('cap-'+encoding,cp_cap(cp_path(cp_cap_points,flags=flags)))
# Marker/DashMode are valid point metadata, not fill-mode selectors. Two
# same-winding subpaths still use Alternate fill in normal/region consumers.
cp_metadata_types=[0,0x11,0x21,0x81,0x20,1,0x11,0xa1]
for name,flags in [('float',0),('relative',0x800)]:
 cp_write('metadata-'+name,cp_fill(cp_path(cp_ring,cp_metadata_types,flags)))
# RLE runs at the six-bit boundary (63+2 line types) retain every vertex.
cp_many=tuple((8+i,12) for i in range(65))+((72,52),(8,52))
for name,flags in [('float',0),('relative',0x800)]:
 cp_write('long-runs-'+name,cp_fill(cp_path(cp_many,flags=flags)))
# Hand-authored PointR bytes exercise Integer15 -16384/+16383 and negative
# deltas; their order is deliberately not generated by relative_scalar().
cp_extreme_points=((-16384,-16384),(-1,-16384),(-1,-1),(-16384,-1))
cp_extreme_coordinates=bytes.fromhex('c0 00 c0 00 bf ff 00 00 bf ff c0 01 00')
cp_extreme_relative=U(PV,4,0x800)+cp_extreme_coordinates+bytes.fromhex('41 00 42 01 41 81')
cp_extreme_relative+=bytes((0xa5,))
cp_extreme_world=ep(0x402A,F(64/16383,0,0,40/16383,8+16384*64/16383,12+16384*40/16383))
cp_write('integer-limits-relative',[cp_extreme_world]+cp_fill(cp_extreme_relative))
cp_write('integer-limits-float',[cp_extreme_world]+cp_fill(cp_path(cp_extreme_points)))
# Both coordinate components independently choose 7- or15-bit forms at the
# signed7 endpoints; a captured translation puts the rectangle in the canvas.
cp_boundary_points=((-64,-64),(63,-64),(63,63),(-64,63))
cp_boundary_world=ep(0x402A,F(.5,0,0,.25,40,24))
for name,flags in [('float',0),('relative',0x800)]:
 cp_write('integer7-boundary-'+name,[cp_boundary_world]+cp_fill(cp_path(cp_boundary_points,flags=flags)))

def cp_bad(name,raw,consumer='normal'):
 if consumer=='region':records=cp_region(raw)
 elif consumer=='cap':records=cp_cap(raw)
 else:records=cp_fill(raw)
 (P/('unsupported-compressed-path-'+name+'.emf')).write_bytes(plus(records))
cp_valid=cp_path(cp_rectangle)
for name,offset,value in [('version',0,0xdeadbeef),('count-overflow',4,0xffffffff),('count-budget',4,1048577),('flags-rle-alone',8,0x1000),('flags-winding',8,0x2000),('flags-reserved',8,0x80000000)]:
 cp_bad(name,pp_changed(cp_valid,offset,U(value)))
cp_bad('float-truncated',U(PV,2,0)+F(8,8,16))
cp_bad('float-nan',U(PV,1,0)+F(float('nan'),8)+bytes((0,)))
cp_bad('float-infinite',U(PV,1,0)+F(8,float('inf'))+bytes((0,)))
cp_bad('short-truncated',U(PV,2,0x4000)+struct.pack('<hhh',8,8,16))
cp_bad('relative-truncated',U(PV,1,0x800)+bytes((0x80,)))
cp_bad('relative-second-truncated',U(PV,1,0x800)+bytes((8,0x80)))
cp_bad('relative-types-truncated',U(PV,1,0x800)+bytes((8,8,0x41)))
cp_bad('rle-zero',U(PV,1,0x800)+bytes((8,8,0x40,0)))
cp_bad('rle-overrun',U(PV,1,0x800)+bytes((8,8,0x42,0)))
cp_bad('rle-marker',U(PV,1,0x800)+bytes((8,8,0x01,0)))
cp_bad('rle-bezier-kind',U(PV,1,0x800)+bytes((8,8,0xc1,0)))
cp_bad('rle-type-reserved',U(PV,1,0x800)+bytes((8,8,0x41,0x40)))
cp_bad('rle-underrun',U(PV,2,0x800)+bytes((8,8,8,0,0x41,0)))
for name,points,types in [('first-line',[(8,8)],[1]),('first-cubic',[(8,8)],[3]),('type-reserved',[(8,8)],[0x40]),('type-unknown',[(8,8)],[2]),('cubic-short',cp_curve[:3],[0,3,3]),('cubic-interrupted',cp_curve[:4],[0,3,1,3]),('cubic-close-control',cp_curve[:4],[0,0x83,3,3]),('cubic-marker-control',cp_curve[:4],[0,0x23,3,3])]:
 # A marker on a cubic control point is meaningful metadata, not malformed;
 # it is tested as an accepted counterpart below instead of in the refusal set.
 if name=='cubic-marker-control':continue
 for encoded,flags in [('float',0),('relative',0x800)]:cp_bad(name+'-'+encoded,cp_path(points,types,flags))
for encoded,flags in [('float',0),('relative',0x800)]:
 cp_write('cubic-metadata-'+encoded,[cp_object(cp_path(cp_curve[:4],[0,0x13,0x23,0x83],flags)),ep(0x4008,pp_pen(width=4),0x200),ep(0x4015,U(0),1)])
cp_bad('trailing-data',cp_valid+U(0))
# The identical malformed relative payload must be refused when embedded in
# RegionNodePath or a default custom cap, not just an ordinary ObjectType3.
cp_bad('region-relative-truncated',U(PV,1,0x800)+bytes((0x80,)),consumer='region')
cp_bad('cap-relative-truncated',U(PV,1,0x800)+bytes((0x80,)),consumer='cap')
cp_bad('region-rle-overrun',U(PV,1,0x800)+bytes((8,8,0x42,0)),consumer='region')
cp_bad('cap-rle-overrun',U(PV,1,0x800)+bytes((8,8,0x42,0)),consumer='cap')
# The existing ellipse-gradient subset is unchanged. Radius10000 and integral
# control5523 differ from the canonical cubic k by0.153<existing0.2 tolerance;
# float/short/relative records carry exactly the SAME thirteen coordinates.
cp_ellipse=((10000,0),(10000,5523),(5523,10000),(0,10000),(-5523,10000),(-10000,5523),(-10000,0),(-10000,-5523),(-5523,-10000),(0,-10000),(5523,-10000),(10000,-5523),(10000,0))
cp_ellipse_types=[0]+[3]*11+[0x83]
def cp_gradient(raw):
 gradient=U(PV,3,1|4,4,0xffff0000)+F(0,0)+U(1,0xff0000ff,len(raw))+raw+preset([(0,0xff0000ff),(.2,0xff0000ff),(.8,0xffff0000),(1,0xffff0000)])
 return [ep(0x4008,gradient,0x100),ep(0x402A,F(.002,0,0,.002,48,32)),ep(0x400E,U(0)+F(-10000,-10000,20000,20000))]
for encoding,flags in [('float',0),('short',0x4000),('relative',0x800),('relative-c',0x4800)]:
 cp_write('gradient-'+encoding,cp_gradient(cp_path(cp_ellipse,cp_ellipse_types,flags)))
(P/'unsupported-compressed-path-gradient-relative-truncated.emf').write_bytes(plus(cp_gradient(U(PV,1,0x800)+bytes((0x80,)))))
def cp_line_type_runs(count):
 out=bytes((0x41,0));remaining=count-1
 while remaining:
  run=min(63,remaining);out+=bytes((0x40|run,1));remaining-=run
 return out
# Each object is independently below the one-million-point limit; only the
# conversion-wide reservation detects their combined1,048,578 points.
cp_half_count=524289
cp_half=U(PV,cp_half_count,0x800)+bytes(2*cp_half_count)+cp_line_type_runs(cp_half_count)
(P/'unsupported-compressed-path-aggregate-points.emf').write_bytes(plus([cp_object(cp_half),cp_object(cp_half,2)]))
# Relative sums must remain bounded, not just each valid Integer15 component.
cp_cumulative_count=61040
cp_cumulative=U(PV,cp_cumulative_count,0x800)+bytes((0,0))+bytes.fromhex('bf ff 00')*(cp_cumulative_count-1)+cp_line_type_runs(cp_cumulative_count)
cp_bad('relative-coordinate-budget',cp_cumulative)
