#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Original compressed raster records. Writes only compressed-raster-* / refused-*.
No renderer invoked. sips encodes the authored JPEG once; all geometry is literal.
"""
from pathlib import Path
import struct,zlib,hashlib,json,tempfile,subprocess
P=Path(__file__).parent
U=lambda *v:struct.pack('<'+'I'*len(v),*v)
I=lambda *v:struct.pack('<'+'i'*len(v),*v)
H=lambda *v:struct.pack('<'+'H'*len(v),*v)
S=lambda *v:struct.pack('<'+'h'*len(v),*v)
F=lambda *v:struct.pack('<'+'f'*len(v),*v)
pad=lambda b:b+b'\0'*(-len(b)%4)
def rec(t,b=b''):return U(t,len(pad(b))+8)+pad(b)
def ep(t,b=b'',flags=0):return H(t,flags)+U(12+len(pad(b)),len(pad(b)))+pad(b)
def emf(rs):
 rs=[*rs,rec(14,U(0,0,20))]
 return U(1,88)+I(0,0,64,64)+I(0,0,1693,1693)+U(0x464d4520,0x10000,88+sum(map(len,rs)),len(rs)+1)+H(32,0)+U(0,0,0)+I(960,960,254,254)+b''.join(rs)
def plus(rs):
 b=b'EMF+'+b''.join([ep(0x4001,U(0xdbc01002,1,96,96),1),*rs,ep(0x4002)])
 return emf([rec(70,U(len(b))+b)])
def obj(t,b,id=0):return ep(0x4008,b,t<<8|id)
def fill(c,r=(0,0,64,64)):return ep(0x400a,U(c,1)+F(*r),0x8000)
def image(raw):return U(0xdbc01002,1)+I(0,0,0)+U(0,1)+raw
def rawimage(colors):return U(0xdbc01002,1)+I(16,16,64)+U(0x26200a,0)+b''.join(bytes((b,g,r,a)) for r,g,b,a in colors)
def pixels(alpha=False):return [((255,0,0,255) if x<8 else (0,255,0,128 if alpha else 255)) if y<8 else ((0,0,255,0 if alpha else 255) if x<8 else (255,255,0,255)) for y in range(16) for x in range(16)]
def png(colors,w=16,h=16):
 def chunk(t,b):return struct.pack('>I',len(b))+t+b+struct.pack('>I',zlib.crc32(t+b)&0xffffffff)
 rows=b''.join(b'\0'+bytes(sum((list(c) for c in colors[y*w:(y+1)*w]),[])) for y in range(h))
 return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(rows))+chunk(b'IEND',b'')
def gif(frames,transparent=False,delay=0,loop=False,delta=False):
 palette=bytes([255,0,0,0,255,0,0,0,255,255,255,0,0,0,0,0,0,0,0,0,0,0,0,0])
 out=b'GIF89a'+H(16,16)+bytes([0xf2,0,0])+palette
 if loop:out+=b'!\xff\x0bNETSCAPE2.0\x03\x01\x00\x00\x00'
 for frame in frames:
  indices=[(0 if x<8 else 1) if y<8 else (4 if transparent and x<8 else 2 if x<8 else 3) for y in range(16) for x in range(16)] if frame==0 else [2]*256
  width=8 if delta and frame else 16;height=width
  if delta and frame:indices=[1 if (x+y)%2 else 4 for y in range(height) for x in range(width)]
  codes=[v for index in indices for v in (8,index)]+[9];bits=''.join(format(v,'04b')[::-1] for v in codes);raw=bytes(int(bits[i:i+8].ljust(8,'0')[::-1],2) for i in range(0,len(bits),8))
  out+=b'!\xf9\x04'+bytes([int(transparent or delta and frame)])+H(delay)+bytes([4,0])+b','+H(0,0,width,height)+b'\0\x03'+b''.join(bytes([len(raw[i:i+255])])+raw[i:i+255] for i in range(0,len(raw),255))+b'\0'
 return out+b';'
def tiff(frames,alpha=False,orientation=1):
 # Little-endian classic TIFF with explicit uncompressed strips and IFD chaining.
 channels=4 if alpha else 3;entries=12 if alpha else 11;block=2+entries*12+4+channels*2+16*16*channels
 out=b'II'+H(42)+U(8)
 for number,colors in enumerate(frames):
  start=8+number*block;bits=start+2+entries*12+4;data=bits+channels*2
  fields=[(256,4,1,16),(257,4,1,16),(258,3,channels,bits),(259,3,1,1),(262,3,1,2),(273,4,1,data),(274,3,1,orientation),(277,3,1,channels),(278,4,1,16),(279,4,1,16*16*channels),(284,3,1,1)]
  if alpha:fields.append((338,3,1,2))
  out+=H(entries)+b''.join(H(tag,kind)+U(count,value) for tag,kind,count,value in sorted(fields))+U(start+block if number+1<len(frames) else 0)+H(*([8]*channels))+bytes(sum((list(c[:channels]) for c in colors),[]))
 return out
BLUE=0xff0000ff
def draw(dest=(8,8,48,48),src=(0,0,16,16),attr=0xffffffff):return ep(0x401a,U(attr,2)+F(*src)+F(*dest))
def scene(im,kind='image',copy=False,extras=(),dest=(8,8,48,48),src=(0,0,16,16),wrap=0):
 rs=[fill(BLUE),ep(0x4023,flags=int(copy)),*extras]
 if kind=='image':rs += [obj(5,im),draw(dest,src)]
 else:
  brush=U(0xdbc01002,2,2,wrap)+F(2,0,0,2,8,8)+im
  if kind=='pen':rs += [obj(2,U(0xdbc01002,0,0,2)+F(12)+brush),ep(0x400d,U(2)+F(8,32,56,32))]
  else:rs += [obj(1,brush),ep(0x400a,U(0,1)+F(8,8,48,48))]
 return plus(rs)
def stretch(raw,compression,wm=False,op=0xcc0020,usage=0,dest=(8,8,48,48),src=(0,0,16,16),headerdim=(16,16),extra=()):
 bmi=U(40)+I(*headerdim)+H(1,0)+U(compression,len(raw),0,0,0,0)
 x,y,w,h=dest;sx,sy,sw,sh=src
 if wm:
  def wr(t,b=b''):b+=b'\0'*(len(b)%2);return U((len(b)+6)//2)+H(t)+b
  rs=[wr(0x20b,S(0,0)),wr(0x20c,S(64,64)),*extra,wr(0xf43,U(op)+H(usage)+S(sh,sw,sy,sx,h,w,y,x)+bmi+raw),wr(0)]
  ph=U(0x9ac6cdd7)+H(0)+S(0,0,64,64)+H(96)+U(0);check=0
  for v in struct.unpack('<10H',ph):check^=v
  return ph+H(check)+H(1,9,0x300)+U((18+sum(map(len,rs)))//2)+H(16)+U(max(len(r)//2 for r in rs))+H(0)+b''.join(rs)
 body=I(0,0,64,64,x,y,sx,sy,sw,sh)+U(80,len(bmi),80+len(bmi),len(raw),usage,op)+I(w,h)+bmi+raw
 return emf([*extra,rec(81,body)])
def write(name,b,ext='emf'):(P/(name+'.'+ext)).write_bytes(b)
old={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in P.iterdir() if f.suffix in ('.emf','.wmf','.png') and not f.name.startswith(('compressed-raster-','refused-compressed-raster-'))}
opaque=pixels();alpha=pixels(True);g=gif([0]);t=tiff([opaque]);ga=gif([0],True);ta=tiff([alpha],True)
with tempfile.TemporaryDirectory() as folder:
 source=Path(folder)/'source.png';target=Path(folder)/'source.jpg';source.write_bytes(png(opaque));subprocess.run(['/usr/bin/sips','-s','format','jpeg','-s','formatOptions','100',str(source),'--out',str(target)],check=True,capture_output=True);jpeg=target.read_bytes()
# Exif is an APP1/JPEG container, not a new magic type. Place a single orientation tag.
def oriented(raw):
 out=raw[:2];p=2
 while raw[p:p+2] not in (b'\xff\xda',b'\xff\xd9'):
  n=int.from_bytes(raw[p+2:p+4],'big');segment=raw[p:p+2+n]
  if not(segment[:2]==b'\xff\xe1' and segment[4:10]==b'Exif\0\0'):out+=segment
  p+=2+n
 payload=b'Exif\0\0II'+H(42)+U(8)+H(1)+H(274,3)+U(1,6)+U(0)
 return out+b'\xff\xe1'+struct.pack('>H',len(payload)+2)+payload+raw[p:]
formats={'gif':g,'tiff':t,'gif-alpha':ga,'tiff-alpha':ta,'jpeg':jpeg,'exif-orientation6':oriented(jpeg),'gif-two-frames':gif([0,1]),'tiff-two-pages':tiff([opaque,[(0,0,255,255)]*256]),'tiff-orientation6':tiff([opaque],orientation=6)}
for delay,loop in [(10,False),(0,True),(10,True)]:formats['gif-two-frames-delay'+str(delay)+('-loop' if loop else '-noloop')]=gif([0,1],delay=delay,loop=loop)
formats['gif-two-frames-delta-noloop']=gif([0,1],delta=True)
formats['gif-two-frames-delta-loop']=gif([0,1],delay=10,loop=True,delta=True)
write('compressed-raster-image-ignored-metadata',scene(U(0xdbc01002,1)+I(-1,-2147483648,3)+U(0xffffffff,1)+t))
for name,raw in formats.items():
 write('compressed-raster-image-'+name,scene(image(raw)))
 (P/('compressed-raster-source-'+name+('.gif' if name.startswith('gif') else '.tiff' if name.startswith('tiff') else '.jpg'))).write_bytes(raw)
for name,raw in [('gif',g),('tiff',t),('gif-alpha',ga),('tiff-alpha',ta)]:
 for kind in ['texture','pen']:write('compressed-raster-'+kind+'-'+name,scene(image(raw),kind))
 for kind in ['texture','pen']:write('compressed-raster-'+kind+'-'+name+'-copy',scene(image(raw),kind,copy=True))
 for copy in [False,True]:write('compressed-raster-alpha-'+name+('-copy' if copy else '-over'),scene(image(raw),copy=copy))
 write('compressed-raster-crop-'+name,scene(image(raw),src=(8,0,8,16)))
 write('compressed-raster-affine-'+name,plus([fill(BLUE),obj(5,image(raw)),ep(0x401b,U(0xffffffff,2)+F(0,0,16,16)+U(3)+F(8,8,48,16,16,56))]))
 write('compressed-raster-clip-'+name,scene(image(raw),extras=[ep(0x4032,F(16,16,24,24))]))
for wrap in range(5):
 write('compressed-raster-wrap-'+str(wrap),scene(image(ta),'texture',wrap=wrap))
 attrs=obj(8,U(0xdbc01002,0,wrap,0x80ffff00,1,0),1)
 write('compressed-raster-attributes-'+str(wrap),plus([fill(BLUE),obj(5,image(ta)),attrs,ep(0x401a,U(1,2)+F(-4,-4,24,24)+F(8,8,48,48))]))
for wrap in range(5):
 write('compressed-raster-control-wrap-'+str(wrap),scene(rawimage(alpha),'texture',wrap=wrap))
 attrs=obj(8,U(0xdbc01002,0,wrap,0x80ffff00,1,0),1)
 write('compressed-raster-control-attributes-'+str(wrap),plus([fill(BLUE),obj(5,rawimage(alpha)),attrs,ep(0x401a,U(1,2)+F(-4,-4,24,24)+F(8,8,48,48))]))
for name,colors in [('opaque',opaque),('gif-alpha',[(r,g,b,0 if a==0 else 255) for r,g,b,a in alpha]),('tiff-alpha',alpha)]:
 for kind in ['image','texture','pen']:write('compressed-raster-control-'+kind+'-'+name,scene(rawimage(colors),kind))
 for kind in ['texture','pen']:write('compressed-raster-control-'+kind+'-'+name+'-copy',scene(rawimage(colors),kind,copy=True))
 for copy in [False,True]:write('compressed-raster-control-'+name+('-copy' if copy else '-over'),scene(rawimage(colors),copy=copy))
for comp,raw,label in [(5,png(opaque),'png'),(4,jpeg,'jpeg')]:
 for wm in [False,True]:
  suffix='wmf' if wm else 'emf'
  write('compressed-raster-stretch-'+label+'-'+suffix,stretch(raw,comp,wm),suffix)
  write('compressed-raster-stretch-mirror-'+label+'-'+suffix,stretch(raw,comp,wm,dest=(56,8,-48,48)),suffix)
  write('compressed-raster-stretch-crop-'+label+'-'+suffix,stretch(raw,comp,wm,src=(8,0,8,16)),suffix)
 write('compressed-raster-stretch-affine-'+label,stretch(raw,comp,extra=[rec(35,F(1,.2,.25,1,-4,-4))]))
 write('compressed-raster-stretch-clip-'+label,stretch(raw,comp,extra=[rec(30,I(16,16,40,40))]))
 for name,kwargs in [('rop',{'op':0x660046}),('usage',{'usage':1}),('dimensions',{'headerdim':(17,16)})]:write('refused-compressed-raster-'+label+'-'+name,stretch(raw,comp,**kwargs))
write('compressed-raster-stretch-png-alpha-emf',stretch(png(alpha),5))
for name,raw in [('bad-signature',b'GIF90a'+b'\0'*30),('truncated-gif',g[:-10]),('truncated-tiff',t[:-20]),('unknown-format',b'BM'+b'\0'*50),('bad-ifd',b'II'+H(42)+U(0xfffffff0))]:write('refused-compressed-raster-'+name,scene(image(raw)))
write('compressed-raster-image-gif-two-frames-visible',scene(image(gif([0,1])),extras=[fill(0xffffffff)]))
write('refused-compressed-raster-jpeg-tag-png-payload',stretch(png(opaque),4))
write('refused-compressed-raster-png-tag-jpeg-payload',stretch(jpeg,5))
write('refused-compressed-raster-topdown-png',stretch(png(opaque),5,headerdim=(16,-16)))
write('refused-compressed-raster-gif-trailing-junk',scene(image(g+b'junk')))
write('refused-compressed-raster-tiff-trailing-junk',scene(image(t+b'junk')))
write('refused-compressed-raster-gif-frame-budget',scene(image(gif([0]+[1]*512,loop=True))))
write('refused-compressed-raster-tiff-dimension-budget',scene(image(t[:18]+U(32769)+t[22:])))
write('refused-compressed-raster-texture-truncated',scene(image(t[:-20]),'texture'))
write('refused-compressed-raster-pen-truncated',scene(image(g[:-10]),'pen'))
# Same valid compressed image redefinitions must consume aggregate native expansion.
large=png([(255,0,0,255)]*(1024*1024),1024,1024)
write('refused-compressed-raster-aggregate',plus([obj(5,image(large)) for _ in range(65)]+[draw(src=(0,0,1024,1024))]))
assert all(hashlib.sha256((P/n).read_bytes()).hexdigest()==h for n,h in old.items()),'Prior payload changed'
print(json.dumps({'unchanged_old_payloads':len(old),'accepted':len(list(P.glob('compressed-raster-*.emf')))+len(list(P.glob('compressed-raster-*.wmf'))),'refused':len(list(P.glob('refused-compressed-raster-*.emf')))},sort_keys=True))
