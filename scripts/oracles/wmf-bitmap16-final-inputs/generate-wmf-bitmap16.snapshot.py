#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Original Bitmap16 transfer wires and independent32bpp DIB controls.
Only this new family is written. No decoder/helper/test process is executed.
MS-WMF META_BITBLT/StretchBlt Bitmap16 has TEN header bytes, not brush32.
"""
import pathlib,struct
P=pathlib.Path(__file__).parent
U=lambda *v:struct.pack('<'+'I'*len(v),*v)
I=lambda *v:struct.pack('<'+'i'*len(v),*v)
H=lambda *v:struct.pack('<'+'H'*len(v),*v)
S=lambda *v:struct.pack('<'+'h'*len(v),*v)
F=lambda *v:struct.pack('<'+'f'*len(v),*v)
def pad(b,n=4):return b+b'\0'*(-len(b)%n)
def wr(t,b=b''):return U((6+len(pad(b,2)))//2)+H(t)+pad(b,2)
def er(t,b=b''):return U(t,8+len(pad(b)))+pad(b)
def brush(color):return wr(0x2fc,H(0)+U(color)+H(0))
def sel(index):return wr(0x12d,H(index))
def rect(l,t,r,b):return wr(0x41b,S(b,r,t,l))
def colors(text=0xff,bg=0xff0000):return [wr(0x209,U(text)),wr(0x201,U(bg))]
def setup():return [wr(0x2fa,H(5)+S(0,0)+U(0)),brush(0xaaaaaa),sel(0),sel(1),rect(0,0,64,64),brush(0x33cc77),sel(2),*colors(),wr(0x107,H(3))]
def wmfb(rs):
 rs=[wr(0x20b,S(0,0)),wr(0x20c,S(64,64)),*setup(),*rs,wr(0)]
 place=U(0x9ac6cdd7)+H(0)+S(0,0,64,64)+H(96)+U(0);check=0
 for n in struct.unpack('<10H',place):check^=n
 return place+H(check)+H(1,9,0x300)+U((18+sum(map(len,rs)))//2)+H(32)+U(max(len(r)//2 for r in rs))+H(0)+b''.join(rs)
def b16(width=8,height=3,stride=None,bits=None,kind=0,planes=1,depth=1):
 stride=((width*depth+15)//16)*2 if stride is None else stride
 if bits is None:bits=bytes((0x81,0xa5,0x42,0x5a,0x24,0x69)) if width==8 and height==3 else bytes(stride*max(height,0))
 return S(kind,width,height,stride)+bytes((planes,depth))+bits
BASE=b16();WIDE=b16(17,3,bits=bytes.fromhex('80 00 ff a5 40 00 7f 5a 20 00 ff 69'))
def dib(bitmap=BASE,text=0xff,bg=0xff0000):
 _,width,height,stride=struct.unpack('<hhhh',bitmap[:8]);bits=bitmap[10:]
 rgb=lambda c:bytes(((c>>16)&255,(c>>8)&255,c&255,0))
 # A 32bpp top-down DIB freezes actual source RGB, independent of live palette.
 depth=bitmap[9]
 if depth==32:pixels=b''.join(bits[y*stride+x*4:y*stride+x*4+3]+b'\0' for y in range(height) for x in range(width))
 else:pixels=b''.join(rgb(bg if bits[y*stride+(x>>3)]&(0x80>>(x&7)) else text) for y in range(height) for x in range(width))
 return U(40)+I(width,-height)+H(1,32)+U(0,len(pixels),0,0,0,0)+pixels
ROP={0xcc:0x00cc0020,0x33:0x00330008,0x66:0x00660046,0x88:0x008800c6,0xee:0x00ee0086,0x44:0x00440328,0xbb:0x00bb0226,0xf0:0x00f00021,0xc0:0x00c000ca,0x96:0x00960169}
def blt(bitmap=BASE,stretch=False,source=(0,0,8,3),dest=(8,8,8,3),rop=0xcc,dibcontrol=False,text=0xff,bg=0xff0000):
 sx,sy,sw,sh=source;dx,dy,dw,dh=dest;value=ROP.get(rop,rop<<16)
 if stretch:prefix=U(value)+S(sh,sw,sy,sx,dh,dw,dy,dx);kind=0xb41 if dibcontrol else 0xb23
 else:
  assert (sw,sh)==(dw,dh)
  prefix=U(value)+S(sy,sx,dh,dw,dy,dx);kind=0x940 if dibcontrol else 0x922
 return wr(kind,prefix+(dib(bitmap,text,bg) if dibcontrol else bitmap))
def write(name,actual,control=None):
 (P/('wmf-bitmap16-'+name+'.wmf')).write_bytes(wmfb(actual))
 if control is not None:(P/('wmf-bitmap16-'+name+'-control.wmf')).write_bytes(wmfb(control))
def pair(name,**kw):write(name,[blt(**kw)],[blt(**kw,dibcontrol=True)])
def bad(name,rs):(P/('unsupported-wmf-bitmap16-'+name+'.wmf')).write_bytes(wmfb(rs))
pair('bitblt-native')
pair('stretch-native',stretch=True)
pair('stretch-upscale',stretch=True,dest=(8,8,32,12))
pair('word-padding17',bitmap=WIDE,stretch=True,source=(0,0,17,3),dest=(8,8,34,12))
pair('type-ignored',bitmap=b16(kind=0x1234))
for name,src,dst in [('crop',(1,1,4,2),(8,8,24,12)),('crop-edge',(6,0,2,3),(8,8,16,18)),('mirror-dest-x',(0,0,8,3),(40,8,-32,12)),('mirror-dest-y',(0,0,8,3),(8,20,32,-12)),('mirror-source-x',(8,0,-8,3),(8,8,32,12)),('mirror-source-y',(0,3,8,-3),(8,8,32,12)),('mirror-both-x',(8,0,-8,3),(40,8,-32,12)),('outside-source',(-2,-1,8,3),(8,8,32,12)),('zero-width',(0,0,0,3),(8,8,32,12)),('zero-dest',(0,0,8,3),(8,8,0,12))]:pair(name,stretch=True,source=src,dest=dst)
for op in ROP:pair('rop-'+format(op,'02x'),stretch=True,dest=(8,8,32,12),rop=op)
for name,rs in [('clip',[wr(0x416,S(18,28,10,12))]),('mapped',[wr(0x20c,S(128,128))]),('translated',[wr(0x20d,S(4,6))])]:
 write(name,rs+[blt(stretch=True,dest=(8,8,32,12))],rs+[blt(stretch=True,dest=(8,8,32,12),dibcontrol=True)])
write('live-colors',[blt(stretch=True,dest=(8,8,32,12)),*colors(0xff00,0xffff),blt(stretch=True,dest=(8,28,32,12))],[blt(stretch=True,dest=(8,8,32,12),dibcontrol=True),*colors(0xff00,0xffff),blt(stretch=True,dest=(8,28,32,12),dibcontrol=True,text=0xff00,bg=0xffff)])
write('save-restore',[wr(0x1e),*colors(0xff00,0xffff),wr(0x416,S(18,28,10,12)),blt(stretch=True,dest=(8,8,32,12)),wr(0x127,S(-1)),blt(stretch=True,dest=(8,28,32,12))],[wr(0x1e),*colors(0xff00,0xffff),wr(0x416,S(18,28,10,12)),blt(stretch=True,dest=(8,8,32,12),dibcontrol=True,text=0xff00,bg=0xffff),wr(0x127,S(-1)),blt(stretch=True,dest=(8,28,32,12),dibcontrol=True)])
# Independently valid earlier gray fill must never escape a refused conversion.
for label,bitmap in [('header-short',BASE[:8]),('bits-short',BASE[:-2]),('trailing',BASE+bytes(2)),('zero-width',b16(width=0,bits=b'')),('negative-width',b16(width=-1,stride=2,bits=b'')),('negative-height',b16(height=-3,bits=b'')),('zero-height',b16(height=0,bits=b'')),('stride-odd',b16(stride=3,bits=bytes(9))),('stride-short',b16(width=17,stride=2,bits=bytes(6))),('planes',b16(planes=2)),('depth4',b16(depth=4,bits=bytes(12))),('depth24',b16(depth=24,bits=bytes(72))),('dimension-budget',b16(width=32767,height=32767,stride=4096,bits=b''))]:bad(label,[blt(bitmap=bitmap)])
for stretch in [False,True]:
 base=blt(stretch=stretch)
 bad(('stretch' if stretch else 'bit')+'-prefix-short',[wr(0xb23 if stretch else 0x922,base[6:10])])
 bad(('stretch' if stretch else 'bit')+'-rop-flags',[wr(0xb23 if stretch else 0x922,U(0x40cc0020)+base[10:])])
# Aggregate decoded reservation, independently below each16Mi pixel limit.
large=b16(2048,4096)
bad('aggregate-budget',[blt(bitmap=large,stretch=True,source=(0,0,1,1),dest=(8,8,1,1))]*9)
# Shared affine EMF+ image parent; source logical bounds stay64x64 exactly once.
def ep(t,b=b'',flags=0):return H(t,flags)+U(12+len(pad(b)),len(pad(b)))+pad(b)
def embedded(child):
 rs=[ep(0x4001,U(0xdbc01002,1,96,96),1),ep(0x400a,U(0xffffffff,1)+F(0,0,64,64),0x8000),ep(0x4008,U(0xdbc01002,2,2,len(child))+child,0x500),ep(0x401b,U(0xffffffff,2)+F(0,0,64,64)+U(3)+F(4,4,60,8,8,60)),ep(0x4002)]
 stream=b'EMF+'+b''.join(rs);records=[er(70,U(len(stream))+stream),er(14,U(0,0,20))]
 return U(1,88)+I(0,0,64,64)+I(0,0,1693,1693)+U(0x464d4520,0x10000,88+sum(map(len,records)),len(records)+1)+H(32,0)+U(0,0,0)+I(960,960,254,254)+b''.join(records)
for suffix,control in [('',False),('-control',True)]:
 (P/('wmf-bitmap16-embedded-affine'+suffix+'.emf')).write_bytes(embedded(wmfb([blt(stretch=True,dest=(8,8,32,12),dibcontrol=control)])))
# Device-specific color storage is irrelevant to a source-independent ROP;
# complete byte framing remains required before skipping its color decoder.
color24=b16(depth=24,bits=bytes(72))
for stretch,label in [(False,'bitblt'),(True,'stretch')]:
 write('source-independent-color24-'+label,[blt(bitmap=color24,stretch=stretch,rop=0xf0)],[blt(stretch=stretch,rop=0xf0,dibcontrol=True)])
bad('source-independent-short-color24',[blt(bitmap=b16(depth=24,bits=bytes(70)),rop=0xf0)])
# Both wrappers appear together: a32-byte pattern object and a10-byte source
# transfer. Pattern choices remain live DC state while the DIB control freezes S.
hatch=[wr(0x102,H(2)),wr(0x2fc,H(2)+U(0x00ff00)+H(2)),sel(3)]
write('pattern-hatch',hatch+[blt(stretch=True,dest=(8,8,32,12),rop=0xc0)],hatch+[blt(stretch=True,dest=(8,8,32,12),rop=0xc0,dibcontrol=True)])
pattern=BASE[:10]+U(0xdeadbeef)+bytes(range(18))+BASE[10:]
pattern_state=[wr(0x1f9,pattern),sel(3)]
write('pattern-bitmap16',pattern_state+[blt(stretch=True,dest=(8,8,32,12),rop=0x96)],pattern_state+[blt(stretch=True,dest=(8,8,32,12),rop=0x96,dibcontrol=True)])

# Measured common-display32bpp profile: B,G,R,X, with arbitrary X ignored.
true32=b16(3,2,depth=32,bits=bytes.fromhex('00 00 ff 00 00 ff 00 80 ff 00 00 ff ff ff 00 01 ff 00 ff 00 00 ff ff 07'))
pair('bgrx32-bitblt',bitmap=true32,source=(0,0,3,2),dest=(8,8,3,2))
pair('bgrx32-stretch',bitmap=true32,stretch=True,source=(0,0,3,2),dest=(8,8,12,8))
for label,value in [('zero',0),('negative',-2),('odd',3),('mismatch',4)]:
 altered=BASE[:6]+S(value)+BASE[8:]
 write('widthbytes-'+label,[blt(bitmap=altered)],[blt(dibcontrol=True)])
# A source-less record samples a snapshot of the preceding destination. The
# independent control stores a hand-authored2x2color atlas, never rendered pixels.
def without(kind='bitblt',source=(4,4,16,8),dest=(28,20,16,8),rop=0xcc):
 sx,sy,sw,sh=source;dx,dy,dw,dh=dest;value=ROP.get(rop,rop<<16)
 if kind in ('bitblt','dibbitblt'):
  assert (sw,sh)==(dw,dh)
  return wr(0x922 if kind=='bitblt' else 0x940,U(value)+S(sy,sx)+H(0xbeef)+S(dh,dw,dy,dx))
 return wr(0xb23 if kind=='stretchblt' else 0xb41,U(value)+S(sh,sw,sy,sx)+H(0xbeef)+S(dh,dw,dy,dx))
def atlas_dib():
 colors=(bytes((0,0,255,0)),bytes((0,255,0,0)),bytes((255,0,0,0)),bytes((0,255,255,0)))
 bits=b''.join(colors[(2 if y>=4 else 0)+(1 if x>=8 else 0)] for y in range(8) for x in range(16))
 return U(40)+I(16,-8)+H(1,32)+U(0,len(bits),0,0,0,0)+bits
def atlas_control(source=(0,0,16,8),dest=(28,20,16,8),rop=0xcc,stretch=False):
 sx,sy,sw,sh=source;dx,dy,dw,dh=dest
 if stretch:return wr(0xb41,U(ROP[rop])+S(sh,sw,sy,sx,dh,dw,dy,dx)+atlas_dib())
 return wr(0x940,U(ROP[rop])+S(sy,sx,dh,dw,dy,dx)+atlas_dib())
def prelude():return [brush(0xff),sel(3),rect(4,4,12,8),brush(0xff00),sel(4),rect(12,4,20,8),brush(0xff0000),sel(5),rect(4,8,12,12),brush(0xffff),sel(6),rect(12,8,20,12),sel(2)]
for kind in ['bitblt','stretchblt','dibbitblt','dibstretchblt']:
 stretch='stretch' in kind
 for label,dest,clip in [('copy',(28,20,16,8),[]),('overlap',(8,4,16,8),[]),('clip',(28,20,16,8),[wr(0x416,S(26,40,22,32))])]:
  write('self-'+kind+'-'+label,prelude()+clip+[without(kind,dest=dest)],prelude()+clip+[atlas_control(dest=dest,stretch=stretch)])
 for op in [0x66,0x96]:write('self-'+kind+'-rop-'+format(op,'02x'),prelude()+[without(kind,rop=op)],prelude()+[atlas_control(rop=op,stretch=stretch)])
 if stretch:
  for label,src,dst,controlsrc in [('mirror-dest',(4,4,16,8),(44,20,-16,8),(0,0,16,8)),('mirror-source',(20,4,-16,8),(28,20,16,8),(16,0,-16,8)),('mirror-both',(20,4,-16,8),(44,20,-16,8),(16,0,-16,8))]:
   write('self-'+kind+'-'+label,prelude()+[without(kind,source=src,dest=dst)],prelude()+[atlas_control(source=controlsrc,dest=dst,stretch=True)])
