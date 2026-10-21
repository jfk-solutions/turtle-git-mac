#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Original 64x64 direct-scanline records; no renderer or test invocation."""
import pathlib,struct,zlib,binascii,base64
P=pathlib.Path(__file__).parent
U=lambda *v:struct.pack('<'+'I'*len(v),*v)
I=lambda *v:struct.pack('<'+'i'*len(v),*v)
H=lambda *v:struct.pack('<'+'H'*len(v),*v)
S=lambda *v:struct.pack('<'+'h'*len(v),*v)
F=lambda *v:struct.pack('<'+'f'*len(v),*v)
def rec(t,b=b''):
 b+=b'\0'*(-len(b)%4);return U(t,len(b)+8)+b
def wr(t,b=b''):
 b+=b'\0'*(len(b)%2);return U((len(b)+6)//2)+H(t)+b
def write(n,rs,wmf=False):
 if wmf:
  rs=[wr(0x20b,S(0,0)),wr(0x20c,S(64,64)),*rs,wr(0)]
  place=U(0x9ac6cdd7)+H(0)+S(0,0,64,64)+H(96)+U(0);check=0
  for x in struct.unpack('<10H',place):check^=x
  value=place+H(check)+H(1,9,0x300)+U((18+sum(map(len,rs)))//2)+H(16)+U(max(len(r)//2 for r in rs))+H(0)+b''.join(rs)
 else:
  rs=[*rs,rec(14,U(0,0,20))]
  value=U(1,88)+I(0,0,64,64)+I(0,0,1693,1693)+U(0x464d4520,0x10000,88+sum(map(len,rs)),len(rs)+1)+H(32,0)+U(0,0,0)+I(960,960,254,254)+b''.join(rs)
 (P/(n+('.wmf' if wmf else '.emf'))).write_bytes(value)
RED=(255,0,0);GREEN=(0,255,0);BLUE=(0,0,255);YELLOW=(255,255,0)
def color(x,y):return (RED if x<16 else GREEN) if y<16 else (BLUE if x<16 else YELLOW)
def dib(depth=32,top=False,width=32,height=32,band=None,solid=None,core=False,compression=0,usage=0):
 rows=height if band is None else band
 palette=b'';masks=b''
 if depth<=8:
  palette=(H(0,1,2,3) if usage else b''.join(bytes([b,g,r])+(b'' if core else b'\0') for r,g,b in [RED,GREEN,BLUE,YELLOW]))
  # CORE always carries the complete 2^depth table.
  if core:palette+=b'\0\0\0'*((1<<depth)-4)
 if compression==3:masks=U(0xf800,0x07e0,0x001f)
 stride=((width*depth+31)//32)*4;bits=bytearray()
 for raw in range(rows):
  y=raw if top else rows-1-raw;row=bytearray(stride)
  for x in range(width):
   r,g,b=solid or color(x,y)
   if depth==32:row[x*4:x*4+4]=bytes([b,g,r,17])
   elif depth==24:row[x*3:x*3+3]=bytes([b,g,r])
   elif depth==16:
    v=((r>>3)<<11)|((g>>2)<<5)|(b>>3) if compression==3 else ((r>>3)<<10)|((g>>3)<<5)|(b>>3)
    row[x*2:x*2+2]=H(v)
   else:
    index=0 if x<width//2 else 1
    if depth==8:row[x]=index
    elif depth==4:row[x//2]|=index<<(0 if x&1 else 4)
    else:row[x//8]|=index<<(7-(x%8))
  bits+=row
 if core:bmi=U(12)+H(width,height,1,depth)+palette
 else:bmi=U(40)+I(width,-height if top else height)+H(1,depth)+U(compression,len(bits),0,0,2 if depth==1 else 4 if depth<=8 else 0,0)+masks+palette
 if depth==1 and not core:bmi=bmi[:40]+(H(0,1) if usage else bytes([0,0,255,0,0,255,0,0]))
 return bmi,bytes(bits)
def emf(bmi,bits,dx=8,dy=8,sx=0,sy=0,cx=32,cy=32,start=0,count=32,usage=0,gaps=False):
 gap=b'GAP!GAP!' if gaps else b'';off=76+len(gap);bitoff=off+len(bmi)+len(gap)
 return rec(80,I(0,0,64,64)+I(dx,dy,sx,sy,cx,cy)+U(off,len(bmi),bitoff,len(bits),usage,start,count)+gap+bmi+gap+bits)
def wmf(bmi,bits,dx=8,dy=8,sx=0,sy=0,cx=32,cy=32,start=0,count=32,usage=0):return wr(0xd33,H(usage,count,start)+S(sy,sx)+H(cy,cx)+S(dy,dx)+bmi+bits)
full=dib();top=dib(top=True)
for name,bitmap in [('bottom',full),('top',top)]:
 write('classic-scanlines-full-'+name,[emf(*bitmap,gaps=True)])
 write('classic-scanlines-wmf-full-'+name,[wmf(*bitmap)],True)
 write('classic-scanlines-partial-'+name,[emf(*dib(top=name=='top',band=8,solid=RED),start=8,count=8)])
 write('classic-scanlines-wmf-partial-'+name,[wmf(*dib(top=name=='top',band=8,solid=RED),start=8,count=8)],True)
write('classic-scanlines-crop',[emf(*full,sx=12,sy=12,cx=16,cy=16)])
write('classic-scanlines-source-outside',[emf(*full,sx=-4,sy=-4,cx=16,cy=16)])
write('classic-scanlines-wmf-negative-destination',[wmf(*full,dx=-8,dy=-8)],True)
write('classic-scanlines-band-rows',[emf(*dib(top=True,band=8),start=8,count=8)])
for topdown in [False,True]:
 bmi,_=dib(top=topdown,band=8)
 rows=[bytes([0,0,255,0])*32]*4+[bytes([255,0,0,0])*32]*4
 if not topdown:rows.reverse()
 write('classic-scanlines-band-asymmetric-'+('top' if topdown else 'bottom'),[emf(bmi,b''.join(rows),start=8,count=8)])
for depth in [1,4,8,16,24,32]:write('classic-scanlines-depth-'+str(depth),[emf(*dib(depth=depth))])
write('classic-scanlines-core',[emf(*dib(depth=4,core=True))])
write('classic-scanlines-bitfields',[emf(*dib(depth=16,compression=3))])
palette=rec(49,U(1)+H(0x300,4)+bytes([255,0,0,0,0,255,0,0,0,0,255,0,255,255,0,0]))
write('classic-scanlines-palette',[palette,rec(48,U(1)),emf(*dib(depth=8,usage=1),usage=1)])
write('classic-scanlines-wmf-palette',[wr(0xf7,H(0x300,4)+bytes([255,0,0,0,0,255,0,0,0,0,255,0,255,255,0,0])),wr(0x234,H(0)),wmf(*dib(depth=8,usage=1),usage=1)],True)
# Whole RLE band: two runs per row, explicit EOL and EOB.
for depth,compression in [(8,1),(4,2)]:
 bmi,_=dib(depth=depth);bits=b''.join(bytes([16,0,16,1 if depth==8 else 0x11,0,0]) for _ in range(32))+bytes([0,1]);bmi=bmi[:16]+U(compression,len(bits))+bmi[24:]
 write('classic-scanlines-rle'+str(depth),[emf(bmi,bits)])
def png(width,height,alpha=False):
 def chunk(kind,payload):return struct.pack('>I',len(payload))+kind+payload+struct.pack('>I',binascii.crc32(kind+payload)&0xffffffff)
 rows=b''.join(b'\0'+(b''.join(bytes([255,0,0,0 if x<width//3 else 128 if x<2*width//3 else 255]) for x in range(width)) if alpha else bytes([255,0,0])*width) for _ in range(height))
 return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,6 if alpha else 2,0,0,0))+chunk(b'IDAT',zlib.compress(rows))+chunk(b'IEND',b'')
bits=png(32,32);bmi=U(40)+I(32,32)+H(1,0)+U(5,len(bits),0,0,0,0)
write('classic-scanlines-png',[emf(bmi,bits)])
write('classic-scanlines-wmf-png',[wmf(bmi,bits)],True)
alpha=png(32,32,True);alphabmi=bmi[:20]+U(len(alpha))+bmi[24:]
write('classic-scanlines-png-alpha',[emf(alphabmi,alpha)])
# Original solid-red source encoded once with macOS ImageIO; embedded bytes
# keep subsequent serialized generation independent of installed image encoders.
jpeg=base64.b64decode('/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAIKADAAQAAAABAAAAIAAAAAD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/8AAEQgAIAAgAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMAAgICAgICAwICAwUDAwMFBgUFBQUGCAYGBgYGCAoICAgICAgKCgoKCgoKCgwMDAwMDA4ODg4ODw8PDw8PDw8PD//bAEMBAgICBAQEBwQEBxALCQsQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEP/dAAQAAv/aAAwDAQACEQMRAD8A+L6KKK/lM/38CiiigD//0Pi+iiiv5TP9/AooooA//9k=')
jpegbmi=U(40)+I(32,32)+H(1,0)+U(4,len(jpeg),0,0,0,0)
write('classic-scanlines-jpeg',[emf(jpegbmi,jpeg)])
write('classic-scanlines-transform-origin',[rec(35,F(2,0,0,2,4,4)),emf(*full,dx=4,dy=4)])
write('classic-scanlines-transform-rotate',[rec(35,F(0,1,-1,0,48,0)),emf(*full,dx=8,dy=8)])
write('classic-scanlines-clip-restore',[rec(33),rec(30,I(16,16,32,32)),rec(20,U(1)),emf(*full),rec(34,I(-1)),emf(*dib(solid=BLUE),dx=48,dy=48,cx=8,cy=8)])
write('classic-scanlines-wmf-map-origin',[wr(0x20c,S(32,32)),wmf(*full,dx=4,dy=4)],True)
# A selected WMF region is a copied device clip; later logical mapping only
# changes the transfer origin, not that device clip or the source pixel size.
rg=H(0x1234,6)+U(0xabcdef01)+S(36,1,2,16,16,32,32)+H(2,16,32,16,32,2)
write('classic-scanlines-wmf-selected-clip',[wr(0x2fc,H(0)+U(0)+H(0)),wr(0x6ff,rg),wr(0x12c,H(1)),wr(0x20c,S(32,32)),wmf(*full,dx=4,dy=4)],True)
write('classic-scanlines-noop',[emf(*full,count=0),emf(*full,start=32),emf(*full,cx=0)])
write('classic-scanlines-two-bands',[emf(*dib(band=16,solid=BLUE),start=0,count=16),emf(*dib(band=16,solid=RED),start=16,count=16)])
prefix=[emf(*dib(solid=RED))]
def bad(name,record,wm=False):write('unsupported-scanlines-'+name,([wmf(*dib(solid=RED))] if wm else prefix)+[record],wm)
bad('truncated-bits',emf(full[0],full[1][:-4]))
bad('fixed',rec(80,b'\0'*64))
bad('offset-fixed',rec(80,I(0,0,64,64)+I(8,8,0,0,32,32)+U(72,40,116,len(full[1]),0,0,32)+full[0]+full[1]))
bad('overlap',rec(80,I(0,0,64,64)+I(8,8,0,0,32,32)+U(76,40,80,len(full[1]),0,0,32)+full[0]+full[1]))
bad('usage',emf(*full,usage=2))
bad('negative-extent',emf(*full,cx=-1))
bad('scan-budget',emf(*full,count=0xffffffff))
bad('planes',emf(full[0][:12]+H(2)+full[0][14:],full[1]))
bad('dimensions',emf(full[0][:4]+I(32769)+full[0][8:],full[1]))
bad('palette',emf(*dib(depth=8,usage=1),usage=1))
bad('header',emf(U(16)+b'\0'*12,b'\0'*32))
bad('rle-partial',emf(U(40)+I(32,32)+H(1,8)+U(1,2,0,0,4,0)+bytes([0,0,255,0])*4,bytes([0,1]),start=1,count=2))
bad('png-size',emf(bmi[:20]+U(len(bits)+1)+bmi[24:],bits))
bad('png-dimensions',emf(bmi[:4]+I(31)+bmi[8:],bits))
bad('png-partial',emf(bmi,bits,count=16))
bad('wmf-truncated',wmf(full[0],full[1][:-4]),True)
bad('wmf-fixed',wr(0xd33,b'\0'*16),True)
bad('wmf-usage',wmf(*full,usage=2),True)
bad('bitfields',emf(dib(depth=16,compression=3)[0][:40]+U(0xf800,0xf800,0x1f),dib(depth=16,compression=3)[1]))
bad('png-signature',emf(bmi,b'X'*len(bits)))
bad('truncated-palette',emf(dib(depth=8)[0][:44],dib(depth=8)[1]))
