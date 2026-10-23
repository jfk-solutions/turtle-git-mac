#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Original deterministic GDI Boolean records. Does not execute a renderer.

MS-EMF 2.3.1.2/2.3.1.6/2.3.1.7 and MS-WMF 2.3.1.2/3/6,2.3.3.12.
ROP3 P=F0,S=CC,D=AA enumerates all eight P/S/D truth rows in one byte;
the independent expected output for truth index n is literally byte n.
ROP2 P=CC,D=AA similarly produces the truth nibble repeated twice.
"""
import pathlib
import struct
P=pathlib.Path(__file__).parent
U=lambda *v:struct.pack('<'+'I'*len(v),*v)
I=lambda *v:struct.pack('<'+'i'*len(v),*v)
H=lambda *v:struct.pack('<'+'H'*len(v),*v)
S=lambda *v:struct.pack('<'+'h'*len(v),*v)
F=lambda *v:struct.pack('<'+'f'*len(v),*v)
def record(kind,body=b''):
 body+=b'\0'*((-len(body))%4)
 return U(kind,len(body)+8)+body
def emf(records,w=64,h=64):
 records=[*records,record(14,U(0,0,20))]
 header=U(1,88)+I(0,0,w,h)+I(0,0,round(w*2540/96),round(h*2540/96))+U(0x464d4520,0x10000,88+sum(map(len,records)),len(records)+1)+H(32,0)+U(0,0,0)+I(960,960,254,254)
 return header+b''.join(records)
def wr(kind,body=b''):
 body+=b'\0'*(len(body)%2)
 return U((len(body)+6)//2)+H(kind)+body
def wmf(records,w=64,h=64):
 records=[wr(0x20b,S(0,0)),wr(0x20c,S(h,w)),*records,wr(0)]
 placeable=U(0x9ac6cdd7)+H(0)+S(0,0,w,h)+H(96)+U(0)
 checksum=0
 for word in struct.unpack('<10H',placeable):checksum^=word
 return placeable+H(checksum)+H(1,9,0x300)+U((18+sum(map(len,records)))//2)+H(16)+U(max(len(x)//2 for x in records))+H(0)+b''.join(records)
def ebrush(handle,gray):return record(39,U(handle,0,gray*0x010101,0))
def eselect(handle):return record(37,U(handle))
def erect(x,y,w,h):return record(43,I(x,y,x+w,y+h))
def ebase(pattern=0xf0,background=0xaa):return [eselect(0x80000008),ebrush(1,background),eselect(1),erect(0,0,64,64),ebrush(2,pattern),eselect(2)]
def wbrush(gray):return wr(0x2fc,H(0)+U(gray*0x010101)+H(0))
def wselect(handle):return wr(0x12d,H(handle))
def wrect(x,y,w,h):return wr(0x41b,S(y+h,x+w,y,x))
def wbase(pattern=0xf0,background=0xaa):return [wselect(0x8008),wbrush(background),wselect(0),wrect(0,0,64,64),wbrush(pattern),wselect(1)]
def dib(gray=0xcc,w=1,h=1):
 bits=bytes([gray,gray,gray,0])*w*h
 return U(40)+I(w,-h)+H(1,32)+U(0,len(bits),0,0,0,0),bits
def eblt(kind,rop,x,y,w=4,h=4,source=True,gray=0xcc,flags=0,usage=0,transform=(1,0,0,1,0,0),indexed=False):
 sw,sh=(w,h) if kind=='bitblt' else (1,1)
 bmi,bits=dib(gray,sw,sh) if source else (b'',b'')
 if indexed:
  # DIB_PAL_COLORS uses WORD logical-palette indices, unlike irrelevant
  # usage1 metadata on a32bpp truecolor bitmap with no color table.
  bits=bytes(((sw+3)//4)*4*sh)
  bmi=U(40)+I(sw,-sh)+H(1,8)+U(0,len(bits),0,0,1,0)+H(20,0)
 if kind=='stretchdibits':
  offset=80 if source else 0
  body=I(x,y,x+w,y+h)+I(x,y,0,0,sw,sh)+U(offset,len(bmi),offset+len(bmi) if source else 0,len(bits),usage,(rop<<16)|flags)+I(w,h)+bmi+bits
  return record(81,body)
 fixed=100 if kind=='bitblt' else 108
 offset=fixed if source else 0
 body=I(x,y,x+w,y+h)+I(x,y,w,h)+U((rop<<16)|flags)+I(0,0)+F(*transform)+U(0,usage,offset,len(bmi),offset+len(bmi) if source else 0,len(bits))
 if kind=='stretchblt':body+=I(sw,sh)
 return record(76 if kind=='bitblt' else 77,body+bmi+bits)
def wblt(kind,rop,x,y,w=4,h=4,source=True,gray=0xcc):
 sw,sh=(w,h) if kind=='dibbitblt' else (1,1)
 bmi,bits=dib(gray,sw,sh) if source else (b'',b'')
 if kind=='dibbitblt':return wr(0x0940,U(rop<<16)+S(0,0,h,w,y,x)+bmi+bits)
 if kind=='dibstretchblt':return wr(0x0b41,U(rop<<16)+S(sh,sw,0,0,h,w,y,x)+bmi+bits)
 return wr(0x0f43,U(rop<<16)+H(0)+S(sh,sw,0,0,h,w,y,x)+bmi+bits)
def patblt(rop,x,y,w,h):return wr(0x061d,U(rop<<16)+S(h,w,y,x))
def write(name,records,kind='emf',w=64,h=64):
 (P/(name+'.'+kind)).write_bytes((emf if kind=='emf' else wmf)(records,w,h))
for kind in ['bitblt','stretchblt','stretchdibits']:
 write('classic-rop3-matrix-'+kind,ebase()+[eblt(kind,rop,(rop%16)*4,(rop//16)*4) for rop in range(256)])
for kind in ['dibbitblt','dibstretchblt','stretchdib']:
 write('wmf-rop3-matrix-'+kind,wbase()+[wblt(kind,rop,(rop%16)*4,(rop//16)*4) for rop in range(256)],'wmf')
# Brush and pen rows exercise the same state but separate geometric coverage.
e=ebase(0xcc)+[record(38,U(3,0)+I(2,0)+U(0xcccccc))]
w=wbase(0xcc)+[wr(0x2fa,H(0)+S(2,0)+U(0xcccccc))]
for n in range(16):
 x=n*4
 e += [record(20,U(n+1)),eselect(0x80000008),erect(x,4,4,12),eselect(3),record(27,I(x,32)),record(54,I(x+4,32))]
 w += [wr(0x104,H(n+1)),wselect(0x8008),wrect(x,4,4,12),wselect(2),wr(0x214,S(32,x)),wr(0x213,S(32,x+4))]
write('classic-rop2-matrix',e);write('wmf-rop2-matrix',w,'wmf')
independent=[0x00,0x05,0x0a,0x0f,0x50,0x55,0x5a,0x5f,0xa0,0xa5,0xaa,0xaf,0xf0,0xf5,0xfa,0xff]
write('wmf-rop3-patblt',wbase()+[patblt(rop,(i%4)*16,(i//4)*16,16,16) for i,rop in enumerate(independent)],'wmf')
for kind in ['bitblt','stretchblt','stretchdibits']:
 write('classic-rop3-no-source-'+kind,ebase()+[eblt(kind,rop,(i%4)*16,(i//4)*16,16,16,source=False) for i,rop in enumerate(independent)])
 # An irrelevant null pattern must not prevent the source-only copy operation.
 write('classic-rop3-null-pattern-'+kind,ebase()+[eselect(0x80000005),eblt(kind,0xcc,8,8,32,32)])
 write('unsupported-raster-required-source-'+kind,[eblt(kind,0xcc,8,8,32,32,source=False)])
 for label,flags in [('capture',0x40000000),('nomirror',0x80000000),('reserved',0x01000000)]:
  write('unsupported-raster-'+kind+'-'+label,[eblt(kind,0xcc,8,8,32,32,flags=flags)])
 write('unsupported-raster-'+kind+'-palette',[eblt(kind,0xcc,8,8,32,32,usage=1,indexed=True)])
# XformSrc only describes the source bitmap. Source-independent operations
# ignore unused zero/singular/skew source metadata while retaining full framing.
for kind in ['bitblt','stretchblt']:
 write('classic-rop3-no-source-transform-'+kind,ebase()+[
  eblt(kind,0xf0,8,8,48,16,source=False,transform=(0,0,0,0,0,0)),
  eblt(kind,0x55,8,36,48,16,source=False,transform=(1,.5,.25,1,900,-900))])
# White opaque DC under transparent/unpainted destination: invert white to black.
write('classic-rop3-white-backdrop',[eblt('bitblt',0x55,8,8,40,40,source=False)])
write('wmf-rop3-white-backdrop',[patblt(0x55,8,8,40,40)],'wmf')
# Repeated XOR must consume the immediately preceding destination, not a stale
# scene snapshot or transparent black. Save/restore freezes device clip geometry.
write('classic-rop3-successive',[eselect(0x80000008),eblt('stretchdibits',0x66,8,8,48,48,gray=0x0f),record(33),record(30,I(24,24,40,40)),eblt('bitblt',0x66,16,16,32,32,gray=0x0f),record(34,I(-1)),eblt('stretchblt',0x66,48,8,8,8,gray=0x0f)])
write('wmf-rop3-successive',[wselect(0x8008),patblt(0x55,8,8,48,48),wr(0x1e),wr(0x416,S(40,40,24,24)),patblt(0x55,16,16,32,32),wr(0x127,S(-1)),patblt(0x55,48,8,8,8)],'wmf')
# Source-state restoration and clipping, with independent world/device mapping.
write('classic-rop2-state',ebase(0xcc)+[record(33),record(20,U(7)),record(30,I(8,8,24,24)),erect(0,0,32,32),record(35,F(1,0,0,1,32,0)),erect(0,8,16,16),record(34,I(-1)),erect(32,8,16,16),record(20,U(11)),erect(0,0,64,64)])
write('wmf-rop2-state',wbase(0xcc)+[wr(0x1e),wr(0x104,H(7)),wr(0x416,S(24,24,8,8)),wrect(0,0,32,32),wr(0x20d,S(0,32)),wrect(0,8,16,16),wr(0x127,S(-1)),wrect(32,8,16,16),wr(0x104,H(11)),wrect(0,0,64,64)],'wmf')
# Explicit native DIB pattern and brush origin. The 2x2 checker is device-fixed.
bmi,bits=dib(0,2,2);bits=bytes([0,0,0,0,255,255,255,0,255,255,255,0,0,0,0,0])
pattern=record(94,U(3,0,32,len(bmi),32+len(bmi),len(bits))+bmi+bits)
write('classic-rop3-pattern-state',[eselect(0x80000008),pattern,eselect(3),eblt('bitblt',0xf0,0,0,24,16,source=False),record(33),record(13,I(1,0)),record(30,I(32,0,56,16)),eblt('stretchdibits',0x5a,24,0,40,16,source=False),record(34,I(-1)),eblt('stretchblt',0xf0,0,24,24,16,source=False),record(35,F(2,0,0,1,32,24)),eblt('bitblt',0xf0,0,0,12,16,source=False)])
write('unsupported-raster-rop2-zero',[record(20,U(0)),*ebase()])
write('unsupported-raster-rop2-seventeen',[record(20,U(17)),*ebase()])
write('unsupported-raster-wmf-rop2-zero',[wr(0x104,H(0)),*wbase()],'wmf')
write('unsupported-raster-patblt-source',[patblt(0xcc,8,8,32,32)],'wmf')
# Actual required-source offsets/counts are malformed, even for source-independent
# operations: declared payloads must not be silently ignored.
for kind in ['bitblt','stretchblt','stretchdibits']:
 value=bytearray(eblt(kind,0x55,8,8,16,16))
 # Both source ranges are relative to record start, never payload start.
 pos=48 if kind=='stretchdibits' else 84
 value[pos:pos+4]=U(0x7ffffff0)
 write('unsupported-raster-'+kind+'-offset',[bytes(value)])
write('unsupported-raster-source-transform',[eblt('bitblt',0xcc,8,8,16,16,transform=(1,0,0,1,float('nan'),0))])
for kind in ['bitblt','stretchblt','stretchdibits']:
 write('unsupported-raster-required-pattern-'+kind,ebase()+[eselect(0x80000005),eblt(kind,0xf0,8,8,16,16,source=False)])
write('unsupported-raster-device-pixel-budget',[eblt('bitblt',0x55,8,8,16,16,source=False)],w=8192,h=4096)
write('unsupported-raster-rop2-short',[record(20,b'')])
# Fractional transformed geometry tests coverage independently of Boolean bytes.
write('classic-rop2-coverage',[eselect(0x80000008),ebrush(1,0xff),eselect(1),record(20,U(1)),record(35,F(1,0,0,1,.5,.5)),erect(8,8,24,24)])
# Four source pixels: red/green/blue/white; crop the middle two in the first
# band, then mirror those same source-world coordinates through x'=4-x.
strip_bmi=U(40)+I(4,-1)+H(1,32)+U(0,16,0,0,0,0)
strip_bits=bytes([0,0,255,0,0,255,0,0,255,0,0,0,255,255,255,0])
def strip(y,transform=(1,0,0,1,0,0)):
 body=I(8,y,56,y+16)+I(8,y,48,16)+U(0xcc0000)+I(1,0)+F(*transform)+U(0,0,108,len(strip_bmi),108+len(strip_bmi),len(strip_bits))+I(2,1)
 return record(77,body+strip_bmi+strip_bits)
write('classic-rop3-source-transform',[strip(8),strip(36,(-1,0,0,1,4,0))])
# Translation+positive scale changes the bitmap interval read from logical source.
scaled_body=I(8,8,56,24)+I(8,8,48,16)+U(0xcc0000)+I(0,0)+F(2,0,0,1,1,0)+U(0,0,108,len(strip_bmi),108+len(strip_bmi),len(strip_bits))+I(1,1)
write('classic-rop3-source-scale',[record(77,scaled_body+strip_bmi+strip_bits)])
for label,transform in [('rotate',(0,1,-1,0,4,0)),('shear',(1,.5,0,1,0,0))]:
 write('unsupported-raster-source-'+label,[eblt('bitblt',0xcc,8,8,16,16,transform=transform)])
# MS-WMF Without Bitmap forms include an ignored Reserved WORD before Dest*.
# Use a nonzero reserved value and zero unused source extents to distinguish the
# specified layout from a truncated with-bitmap form or a guessed DIB offset.
def wwithout(kind,rop,x,y,w=16,h=16):
 if kind in ['bitblt','dibbitblt']:
  return wr(0x0922 if kind=='bitblt' else 0x0940,U(rop<<16)+S(0,0)+H(0xbeef)+S(h,w,y,x))
 return wr(0x0b23 if kind=='stretchblt' else 0x0b41,U(rop<<16)+S(0,0,0,0)+H(0xbeef)+S(h,w,y,x))
for kind in ['bitblt','stretchblt','dibbitblt','dibstretchblt']:
 write('wmf-rop3-without-bitmap-'+kind,wbase()+[wwithout(kind,rop,(i%4)*16,(i//4)*16) for i,rop in enumerate(independent)],'wmf')
 write('unsupported-raster-wmf-without-bitmap-source-'+kind,[wwithout(kind,0xcc,8,8)],'wmf')
# Complete device-dependent Bitmap16 inputs remain an explicit refusal, despite
# the source-independent Without Bitmap forms above now being supported.
ddb=H(0,8,8,32)+bytes([1,32])+bytes([0xcc,0xcc,0xcc,0])*64
write('unsupported-raster-device-bitblt',[wr(0x0922,U(0xcc0020)+S(0,0,8,8,0,0)+ddb)],'wmf')
write('unsupported-raster-device-stretchblt',[wr(0x0b23,U(0xcc0020)+S(8,8,0,0,16,16,0,0)+ddb)],'wmf')
# Positive DIB height stores rows bottom-up. For StretchDIBits/STRETCHDIB,
# ySrc=0,cySrc=2 selects the bottom two of four logical color bands: blue/yellow,
# not the top red/green bands. The partial crop distinguishes both conventions.
bottom_bmi=U(40)+I(1,4)+H(1,32)+U(0,16,0,0,0,0)
bottom_bits=bytes([0,255,255,0,255,0,0,0,0,255,0,0,0,0,255,0])
bottom_emf=I(16,8,48,56)+I(16,8,0,0,1,2)+U(80,len(bottom_bmi),120,len(bottom_bits),0,0xcc0000)+I(32,48)+bottom_bmi+bottom_bits
write('classic-rop3-source-bottom-up',[record(81,bottom_emf)])
bottom_wmf=U(0xcc0000)+H(0)+S(2,1,0,0,48,32,8,16)+bottom_bmi+bottom_bits
write('wmf-rop3-source-bottom-up',[wr(0x0f43,bottom_wmf)],'wmf')
