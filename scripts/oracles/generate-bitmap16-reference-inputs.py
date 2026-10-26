#!/usr/bin/env python3
# Original synthetic MS-WMF Bitmap16 transfer wires, no renderer code.
from pathlib import Path
import struct
P=Path(__file__).parent/'wmf-bitmap16-inputs'
U=lambda *v:struct.pack('<'+'I'*len(v),*v)
H=lambda *v:struct.pack('<'+'H'*len(v),*v)
S=lambda *v:struct.pack('<'+'h'*len(v),*v)
def rec(t,b=b''):
 b+=b'\0'*(len(b)%2);return U((6+len(b))//2)+H(t)+b
def brush(r,g,b):return rec(0x2fc,H(0)+U(r|g<<8|b<<16)+H(0))
def setup():return [rec(0x103,H(8)),rec(0x20c,S(160,240)),brush(70,130,80),rec(0x12d,H(0)),rec(0x61d,U(0xf00021)+S(160,240,0,0)),brush(190,170,30),rec(0x12d,H(1)),rec(0x209,U(220|20<<8|40<<16)),rec(0x201,U(20|80<<8|210<<16)),rec(0x107,H(3))]
def write(name,rs):
 rs=setup()+rs+[rec(0)];pl=U(0x9ac6cdd7)+H(0)+S(0,0,240,160)+H(96)+U(0);ck=0
 for w in struct.unpack('<10H',pl):ck^=w
 (P/(name+'.wmf')).write_bytes(pl+H(ck)+H(1,9,0x300)+U((18+sum(map(len,rs)))//2)+H(32)+U(max(len(r)//2 for r in rs))+H(0)+b''.join(rs))
def bits(bpp,w,h):
 stride=((w*bpp+15)>>4)<<1;b=bytearray(stride*h);rows=[0xa5,0x5a,0x81,0x7e];colors=[(255,0,0),(0,255,0),(0,0,255),(255,255,255),(0,0,0),(255,255,0),(255,0,255),(0,255,255)]
 for y in range(h):
  for x in range(w):
   r,g,blue=colors[(x+y*3)%8];o=y*stride
   if bpp==1:b[o+x//8]|=((rows[y%4]>>(7-x%8))&1)<<(7-x%8)
   elif bpp==4:b[o+x//2]|=((x+y*3)%16)<<(0 if x%2 else 4)
   elif bpp==8:b[o+x]=(x+y*3)*17
   elif bpp==16:struct.pack_into('<H',b,o+x*2,(r>>3)<<10|(g>>3)<<5|blue>>3)
   else:b[o+x*(bpp//8):o+(x+1)*(bpp//8)]=bytes([blue,g,r]+([(x*47+y*29)&255]if bpp==32 else[]))
 return bytes(b)
def bitmap(bpp=1,w=8,h=4,type=0,stride=None,planes=1):return S(type,w,h,((w*bpp+15)>>4)<<1 if stride is None else stride)+bytes([planes,bpp])+bits(bpp,w,abs(h))
def blt(stretch=False,bmp=None,rop=0xcc0020,src=(0,0,8,4),dest=(8,8,8,4),reserved=None):
 sx,sy,sw,sh=src;dx,dy,dw,dh=dest
 head=U(rop)+(S(sh,sw,sy,sx)if stretch else S(sy,sx))
 if reserved is not None:head+=H(reserved)
 head+=S(dh,dw,dy,dx)
 return rec(0xb23 if stretch else 0x922,head+(bitmap()if bmp is None and reserved is None else bmp or b''))
for bpp in [1,4,8,16,24,32]:
 for stretch in [False,True]:write('hand-bpp'+str(bpp)+('-stretch'if stretch else'-bitblt'),[blt(stretch,bmp=bitmap(bpp),dest=(8,8,32,16)if stretch else(8,8,8,4))])
for stretch in [False,True]:write('hand-crop'+('-stretch'if stretch else'-bitblt'),[blt(stretch,src=(2,1,4,2),dest=(8,8,24,12)if stretch else(8,8,4,2))])
for v in range(4):write('hand-mirror'+str(v),[blt(True,src=(8 if v&1 else 0,0,-8 if v&1 else 8,4),dest=(48,32,-32 if v&2 else 32,16))])
for rop in [0xcc0020,0x330008,0x8800c6,0xee0086,0x660046,0xc000ca,0xf00021,0x550009,0x42,0xff0062]:write('hand-rop'+str(rop),[blt(rop=rop)])
write('hand-wordstride17',[blt(bmp=bitmap(w=17,h=3),src=(0,0,17,3),dest=(8,8,17,3))])
for name,bmp in [('type17',bitmap(type=17)),('extra-stride',bitmap(stride=4)),('planes2',bitmap(planes=2)),('negative-height',bitmap(h=-4))]:write('hand-'+name,[blt(bmp=bmp)])
for stretch in [False,True]:
 for rop in [0xcc0020,0xf00021,0x550009,0x42,0xff0062]:write('omitted-'+('stretch'if stretch else'bitblt')+'-rop'+str(rop),[brush(255,0,0),rec(0x12d,H(2)),rec(0x61d,U(0xf00021)+S(4,8,4,4)),rec(0x12d,H(1)),blt(stretch,rop=rop,src=(4,4,8,4),dest=(32,8,8,4),reserved=0xa5a5)])
