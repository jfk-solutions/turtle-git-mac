#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Original size-delimited embedded WMF/EMF/EMF+ and texture records.
MS-EMFPLUS 2.1.1.20 / 2.2.2.27 / 2.2.2.46; no third-party artwork.
Only embedded-* fixtures are written. No renderer is executed.
"""
from pathlib import Path
import struct, zlib, hashlib, json
P=Path(__file__).parent
U=lambda *v:struct.pack('<'+'I'*len(v),*v)
I=lambda *v:struct.pack('<'+'i'*len(v),*v)
H=lambda *v:struct.pack('<'+'H'*len(v),*v)
S=lambda *v:struct.pack('<'+'h'*len(v),*v)
F=lambda *v:struct.pack('<'+'f'*len(v),*v)
pad=lambda b:b+b'\0'*((-len(b))%4)
def rec(t,b=b''):return U(t,len(pad(b))+8)+pad(b)
def ep(t,b=b'',flags=0):return H(t,flags)+U(12+len(pad(b)),len(b))+pad(b)
def comment(rs):
 b=b'EMF+'+b''.join(rs);return rec(70,U(len(b))+b)
def emf(rs,w=64,h=64):
 rs=[*rs,rec(14,U(0,0,20))]
 return U(1,88)+I(0,0,w,h)+I(0,0,round(w*2540/96),round(h*2540/96))+U(0x464d4520,0x10000,88+sum(map(len,rs)),len(rs)+1)+H(32,0)+U(0,0,0)+I(960,960,254,254)+b''.join(rs)
def plus(rs,w=64,h=64,dual=True):return emf([comment([ep(0x4001,U(0xdbc01002,1,96,96),int(dual)),*rs,ep(0x4002)])],w,h)
def fill(color,rect=(0,0,64,64)):return ep(0x400a,U(color,1)+F(*rect),0x8000)
def obj(t,body,id=0):return ep(0x4008,body,t<<8|id)
def image(t,b):return U(0xdbc01002,2,t,len(b))+b
def draw(id=0,dest=(8,8,32,32),src=(0,0,16,16),attr=0xffffffff):return ep(0x401a,U(attr,2)+F(*src)+F(*dest),id)
def mode(value):return ep(0x4023,flags=value)
def ebrush(id,c):return rec(39,U(id,0,c,0))
def esel(id):return rec(37,U(id))
def erect(x,y,w,h):return rec(43,I(x,y,x+w,y+h))
def classic():return emf([esel(0x80000008),ebrush(1,0xff),esel(1),erect(2,2,6,12),ebrush(2,0xff00),esel(2),erect(8,2,6,6)],16,16)
def wr(t,b=b''):
 b+=b'\0'*(len(b)%2);return U((len(b)+6)//2)+H(t)+b
def wmf(placeable=False):
 rs=[wr(0x20b,S(0,0)),wr(0x20c,S(16,16)),wr(0x12d,H(0x8008)),wr(0x2fc,H(0)+U(0xff)+H(0)),wr(0x12d,H(0)),wr(0x41b,S(14,8,2,2)),wr(0x2fc,H(0)+U(0xff00)+H(0)),wr(0x12d,H(1)),wr(0x41b,S(8,14,2,8)),wr(0)]
 header=H(1,9,0x300)+U((18+sum(map(len,rs)))//2)+H(16)+U(max(len(r)//2 for r in rs))+H(0)
 if not placeable:return header+b''.join(rs)
 ph=U(0x9ac6cdd7)+H(0)+S(0,0,16,16)+H(96)+U(0);checksum=0
 for word in struct.unpack('<10H',ph):checksum^=word
 return ph+H(checksum)+header+b''.join(rs)
BLUE=0xff0000ff
children={1:wmf(),2:wmf(True),3:classic(),4:plus([fill(0xffff0000,(2,2,6,12)),fill(0xff00ff00,(8,2,6,6))],16,16,False),5:plus([fill(0xffff0000,(2,2,6,12)),fill(0xff00ff00,(8,2,6,6))],16,16,True)}
def scene(t,b,extra=(),dest=(8,8,32,32),src=(0,0,16,16),attrs=None):
 rs=[fill(BLUE),obj(5,image(t,b))]
 if attrs:rs+=[obj(8,U(0xdbc01002,0,attrs[0],attrs[1],attrs[2] if len(attrs)>2 else 0,0),1)]
 return plus(rs+list(extra)+[draw(dest=dest,src=src,attr=1 if attrs else 0xffffffff)])
def write(name,b):
 if not name.startswith('embedded-'):raise ValueError(name)
 (P/(name+'.emf')).write_bytes(b)
def png(name,pixel):
 def chunk(t,b):return struct.pack('>I',len(b))+t+b+struct.pack('>I',zlib.crc32(t+b)&0xffffffff)
 raw=b''.join(b'\0'+b''.join(bytes(pixel(x+.5,y+.5)) for x in range(64)) for y in range(64))
 (P/(name+'.png')).write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',64,64,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b''))
old={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in P.iterdir() if f.suffix in ('.emf','.wmf','.png') and not f.name.startswith('embedded-')}
for t,label in [(1,'wmf'),(2,'placeable'),(3,'emf'),(4,'plus-only'),(5,'plus-dual')]:write('embedded-image-'+label,scene(t,children[t]))
def ink(x,y):return (255,0,0,255) if 2<=x<8 and 2<=y<14 else (0,255,0,255) if 8<=x<14 and 2<=y<8 else None
png('embedded-image-control',lambda x,y:ink((x-8)/2,(y-8)/2) or (0,0,255,255))
for t in children:write('embedded-image-crop-'+str(t),scene(t,children[t],dest=(8,8,32,32),src=(4,0,8,16)))
# A second nested image, definition reuse, transformed placement, and parent clip.
level=plus([obj(5,image(4,children[4])),draw(dest=(0,0,16,16))],16,16,False)
write('embedded-image-recursive',scene(4,level))
write('embedded-image-repeated',plus([fill(BLUE),obj(5,image(4,children[4])),draw(dest=(0,0,32,32)),draw(dest=(32,32,32,32))]))
write('embedded-image-world-clip',scene(4,children[4],[ep(0x4032,F(16,8,24,24)),ep(0x402a,F(1,.25,.5,1,8,0))]))
# Three points explicitly exercise affine destination mapping without bbox guesses.
write('embedded-image-affine',plus([fill(BLUE),obj(5,image(4,children[4])),ep(0x401b,U(0xffffffff,2)+F(0,0,16,16)+U(3)+F(8,8,40,16,16,48))]))
for wrap in range(5):
 write('embedded-image-attributes-'+str(wrap),scene(4,children[4],dest=(8,8,48,48),src=(-8,-8,32,32),attrs=(wrap,0x80ffff00)))
write('embedded-image-attributes-clamp-ignored',scene(4,children[4],dest=(8,8,48,48),src=(-8,-8,32,32),attrs=(4,0x80ffff00,1)))
# Texture pixels are derived from a transparent owned image surface. The exact
# child bytes and brush placement match a separate literal raw-bitmap control.
raw=bytearray()
for y in range(16):
 for x in range(16):
  r,g,b,a=ink(x+.5,y+.5) or (0,0,0,0);raw+=bytes((b,g,r,a))
bitmap=U(0xdbc01002,1)+I(16,16,64)+U(0x26200a,0)+raw
def texture(im,wrap=0):return U(0xdbc01002,2,2,wrap)+F(2,0,0,2,8,8)+im
def texture_scene(im,wrap=0,copy=False,stroke=False,text=False):
 brush=texture(im,wrap);rs=[fill(BLUE),mode(int(copy))]
 if stroke:
  pen=U(0xdbc01002,0,0,2)+F(12)+brush
  rs += [obj(2,pen),ep(0x400d,U(2)+F(8,32,56,32))]
 elif text:
  face='Helvetica'.encode('utf-16le');font=U(0xdbc01002)+F(36)+U(2,0,0,len(face)//2)+face
  rs += [obj(1,brush),obj(6,font,1),ep(0x401c,U(0,0xffffffff,1)+F(8,8,48,48)+'H'.encode('utf-16le'),1)]
 else:rs += [obj(1,brush),ep(0x400a,U(0,1)+F(8,8,48,48))]
 return plus(rs)
for t in children:write('embedded-texture-'+str(t),texture_scene(image(t,children[t])))
for wrap in range(5):
 write('embedded-texture-wrap-'+str(wrap),texture_scene(image(4,children[4]),wrap))
 write('embedded-texture-wrap-'+str(wrap)+'-control',texture_scene(bitmap,wrap))
for label,kw in [('copy',{'copy':True}),('stroke',{'stroke':True}),('glyph',{'text':True})]:
 write('embedded-texture-'+label,texture_scene(image(4,children[4]),**kw));write('embedded-texture-'+label+'-control',texture_scene(bitmap,**kw))
# Parent state is live; non-painted child viewport pixels must not clear it.
for label,child_records in [('inherit',[fill(0x80ff0000,(2,2,12,12))]),('over',[mode(0),fill(0x80ff0000,(2,2,12,12))]),('copy',[mode(1),fill(0x00ff0000,(2,2,12,12))])]:
 child=plus(child_records,16,16,False)
 write('embedded-compositing-'+label,scene(4,child,[mode(0 if label=='copy' else 1)]))
write('embedded-parent-state',plus([fill(BLUE),mode(1),obj(5,image(4,plus([mode(0),fill(0x80ff0000,(2,2,12,12))],16,16,False))),draw(),fill(0x8000ff00,(40,8,16,16))]))
# Classic DSTINVERT must inspect the live parent blue, not an empty child.
blt=I(2,2,14,14)+I(2,2,12,12)+U(0x00550009)+I(0,0)+F(1,0,0,1,0,0)+U(0,0,0,0,0,0)
write('embedded-image-destination-rop',scene(3,emf([rec(76,blt)],16,16)))
child=plus([mode(1),fill(0x00ff0000,(2,2,12,12))],16,16,False)
tex=texture(image(4,child))
write('embedded-checkpoint-scopes',plus([fill(BLUE),mode(1),fill(0x80ff0000,(0,0,8,8)),obj(1,tex),ep(0x400a,U(0,1)+F(8,8,48,48)),fill(0x8000ff00,(56,56,8,8))]))
write('embedded-child-clear',scene(4,plus([ep(0x4009,U(0))],16,16,False)))
# Unsupported children fail the whole outer picture. Lengths are independently
# corrupt at every layer, never accepted by a permissive successful blank image.
bad={
 'size-truncated':U(0xdbc01002,2,4,len(children[4])+4)+children[4],
 'size-trailing':image(4,children[4])+b'1234',
 'type':image(6,children[4]),'type-header':image(1,children[4]),
 'plus-header-kind':image(4,children[5]),'empty':image(4,b''),
 'child-truncated':image(4,children[4][:-4]),
 'child-unsupported':image(4,plus([ep(0x4037)],16,16,False)),
 'child-image-reference':image(4,plus([draw(id=63)],16,16,False)),
 'child-font-reference':image(4,plus([ep(0x401c,U(0xff000000,0xffffffff,1)+F(0,0,16,16)+H(65),0x803f)],16,16,False)),
}
for name,im in bad.items():write('embedded-refused-'+name,plus([fill(BLUE),obj(5,im),draw()]))
write('embedded-refused-attribute-clamp',scene(4,children[4],attrs=(4,0,2)))
write('embedded-refused-texture-child',texture_scene(bad['child-unsupported']))
write('embedded-refused-missing-reference',plus([fill(BLUE),draw(63)]))
nested=children[4]
for _ in range(10):nested=plus([obj(5,image(4,nested)),draw(dest=(0,0,16,16))],16,16,False)
write('embedded-refused-recursion',scene(4,nested))
write('embedded-refused-playback-count',plus([obj(5,image(4,children[4]))]+[draw(dest=(0,0,16,16))]*4100))
# All existing original fixtures are immutable across generator extension.
assert old=={name:hashlib.sha256((P/name).read_bytes()).hexdigest() for name in old}
print(json.dumps({'accepted':len(list(P.glob('embedded-*.emf')))-len(list(P.glob('embedded-refused-*.emf'))),'refused':len(list(P.glob('embedded-refused-*.emf'))),'controls':len(list(P.glob('embedded-*.png'))),'earlier_unchanged':len(old)},sort_keys=True))
