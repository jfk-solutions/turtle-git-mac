#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Original classic bitmap-brush wire records; no renderer or tests are executed."""
import pathlib,struct
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
  value=place+H(check)+H(1,9,0x300)+U((18+sum(map(len,rs)))//2)+H(32)+U(max(len(r)//2 for r in rs))+H(0)+b''.join(rs)
 else:
  rs=[*rs,rec(14,U(0,0,20))]
  value=U(1,88)+I(0,0,64,64)+I(0,0,1693,1693)+U(0x464d4520,0x10000,88+sum(map(len,rs)),len(rs)+1)+H(32,0)+U(0,0,0)+I(960,960,254,254)+b''.join(rs)
 (P/(n+('.wmf' if wmf else '.emf'))).write_bytes(value)
def ws(h):return wr(0x12d,H(h))
def wrect(l,t,r,b):return wr(0x41b,S(b,r,t,l))
def wb(c):return wr(0x2fc,H(0)+U(c)+H(0))
def wcolors(text=255,bg=0xff0000):return [wr(0x209,U(text)),wr(0x201,U(bg))]
def bitmap16(width=8,height=2,stride=2,planes=1,depth=1,bits=bytes([0x80,0xa5,0x40,0x5a]),kind=0):
 # DDB storage is top-down. Bytes outside width are distinctive padding.
 # Ignored Bits DWORD and eighteen Reserved bytes deliberately contain data.
 return H(kind)+S(width,height,stride)+bytes([planes,depth])+U(0x1234abcd)+bytes(range(1,19))+bits
def wpattern(**kw):return wr(0x1f9,bitmap16(**kw))
def wsetup(**kw):return [ws(0x8008),*wcolors(),wr(0x102,H(1)),wpattern(**kw),ws(0)]
write('wmf-classic-patternbrush-mono',wsetup(kind=0x1234)+[wrect(0,0,64,64)],True)
write('wmf-classic-patternbrush-state',wsetup()+[wrect(0,0,64,16),wr(0x1e),*wcolors(0x00ff00,0x00ffff),wrect(0,16,64,32),wr(0x127,S(-1)),wrect(0,32,64,48),ws(0x8000),wr(0x1f0,H(0)),wb(0x00ff00),ws(0),wrect(0,48,64,64)],True)
# Clip and origin use device coordinates; changing logical scale must not
# enlarge a DDB's native tile. Explicit shared consumers are added below.
write('wmf-classic-patternbrush-clip',wsetup()+[wr(0x416,S(48,48,8,8)),wrect(0,0,64,64)],True)
# A valid earlier solid primitive proves malformed or unsupported layouts refuse the entire
# conversion, not merely the malformed brush and subsequent paintings.
prefix=[ws(0x8008),wb(255),ws(0),wrect(0,0,6,6)]
for name,body in {
 'short-prefix':bitmap16()[:30],
 'bits-truncated':bitmap16(bits=b'\x80\0'),
 'zero-width':bitmap16(width=0),
 'negative-height':bitmap16(height=-2),
 'odd-stride':bitmap16(stride=1),
 'planes':bitmap16(planes=2),
 'depth':bitmap16(depth=4),
 'budget':bitmap16(width=32767,height=32767,stride=4096,bits=b''),
}.items():write('unsupported-classic-patternbrush-wmf-'+name,prefix+[wr(0x1f9,body),ws(1),wrect(8,8,56,56)],True)
def es(h):return rec(37,U(h))
def erect(l,t,r,b):return rec(43,I(l,t,r,b))
def ecolors(text=255,bg=0xff0000):return [rec(24,U(text)),rec(25,U(bg))]
def mono(handle=1,usage=2,height=-2,kind=93,palette=None,gaps=True,width=8,depth=1,bits=None):
 rows=[bytes([0x80,0xa5,0x96,0x69]),bytes([0x40,0x5a,0x69,0x96])]
 if height>0:rows.reverse()
 if bits is None:bits=b''.join(rows)
 table=b'' if usage==2 else (palette if palette is not None else bytes([0,0,0,0,255,255,255,0]))
 bmi=U(40)+I(width,height)+H(1,depth)+U(0,len(bits),0,0,0,0)+table
 gap=b'gap!gap!' if gaps else b'';off_bmi=32+len(gap);off_bits=off_bmi+len(bmi)+len(gap)
 return rec(kind,U(handle,usage,off_bmi,len(bmi),off_bits,len(bits))+gap+bmi+gap+bits)
def esetup(**kw):return [es(0x80000008),*ecolors(),rec(18,U(1)),mono(**kw),es(1)]
write('classic-monobrush-dynamic',esetup()+[erect(0,0,64,64)])
write('classic-monobrush-bottom-up',esetup(height=2)+[erect(0,0,64,64)])
write('classic-monobrush-black-white',esetup(usage=0)+[erect(0,0,64,64)])
# Fixed palettes are RGBQUAD (B,G,R,Reserved), not COLORREF. These arbitrary
# colors must remain fixed on the renderer's color DC despite live DC colors.
colored=bytes([0,255,0,0,0,0,255,0])
write('classic-monobrush-colored',esetup(usage=0,palette=colored)+[erect(0,0,64,64)])
write('classic-patternbrush-dib-fixed',esetup(usage=0,kind=94)+[erect(0,0,64,64)])
write('classic-monobrush-state',esetup()+[erect(0,0,64,16),rec(33),*ecolors(0x00ff00,0x00ffff),erect(0,16,64,32),rec(34,I(-1)),erect(0,32,64,48),es(0x80000000),rec(40,U(1)),rec(39,U(1,0,0x00ff00,0)),es(1),erect(0,48,64,64)])
write('wmf-classic-patternbrush-wide',wsetup()[:4]+[wpattern(width=17,stride=4,bits=bytes([0x80,0,0x80,0x5a,0x40,0,0,0xa5])),ws(0),wrect(0,0,64,64)],True)
write('classic-monobrush-clip-origin',esetup()+[rec(13,I(1,1)),rec(33),rec(30,I(8,8,32,32)),rec(35,F(2,0,0,2,0,0)),erect(0,0,32,32),rec(34,I(-1)),erect(40,40,56,56)])
write('classic-monobrush-rop2',esetup()+[rec(20,U(7)),erect(8,8,56,56)])
def eregion(rs):return U(32,1,len(rs),16*len(rs))+I(min(r[0] for r in rs),min(r[1] for r in rs),max(r[2] for r in rs),max(r[3] for r in rs))+b''.join(I(*r) for r in rs)
rg=eregion([(8,8,56,56)])
write('classic-monobrush-region',esetup()+[rec(71,I(0,0,64,64)+U(len(rg),1)+rg)])
write('classic-monobrush-flood',esetup()+[rec(30,I(8,8,32,32)),rec(53,I(10,10)+U(0xffffff,1))])
write('wmf-classic-patternbrush-rop2',wsetup()+[wr(0x104,H(7)),wrect(8,8,56,56)],True)
write('wmf-classic-patternbrush-patblt',wsetup()+[wr(0x61d,U(0x005a0049)+S(48,48,8,8))],True)
# FILLREGION explicitly references pattern brush0 and independent region1.
scan=H(2)+S(8,56,8,56)+H(2)
region=H(0x1234,6)+U(0x12345678)+S(24+len(scan),1,2)+S(8,8,56,56)+scan
write('wmf-classic-patternbrush-region',wsetup()+[wr(0x6ff,region),wr(0x228,H(0,1))],True)
write('wmf-classic-patternbrush-flood',wsetup()+[wr(0x416,S(32,32,8,8)),wr(0x548,H(1)+U(0xffffff)+S(10,10))],True)
# Valid image before malformed object cannot escape as a partial conversion.
eprefix=[es(0x80000008),rec(39,U(2,0,255,0)),es(2),erect(0,0,6,6)]
valid=mono();payload=valid[8:]
bad={
 'short':rec(93,U(1,2,32)),
 'usage':mono(usage=3),
 'depth':mono(depth=4),
 'truncated-bits':mono(bits=b'\x80\0\0\0'),
 'zero-width':mono(width=0),
 'handle':mono(handle=0x80000001),
}
# Corrupt exact record-relative offsets independently of normal generator math.
for name,offset,value in [('bmi-fixed-overlap',8,12),('bits-overlap',16,40),('bits-oob',16,0xfffffffc),('bmi-size',12,8)]:
 body=bytearray(payload);struct.pack_into('<I',body,offset,value);bad[name]=rec(93,body)
for name,value in bad.items():write('unsupported-classic-patternbrush-emf-'+name,eprefix+[value,es(1),erect(8,8,56,56)])

def palette(handle,colors):return rec(49,U(handle)+H(0x300,len(colors))+b''.join(bytes([r,g,b,0]) for r,g,b in colors))
# Logical palette WORDs resolve when selected into the target DC, not when
# the object is created. SaveDC/RestoreDC preserve the selected palette/brush.
write('classic-monobrush-palette-select',[es(0x80000008),*ecolors(),mono(usage=1,palette=H(0,1)),es(1),palette(3,[(0,255,0),(255,0,0)]),palette(4,[(0,255,255),(255,255,0)]),rec(48,U(3)),es(1),erect(0,0,64,16),rec(33),rec(48,U(4)),es(1),erect(0,16,64,32),rec(34,I(-1)),erect(0,32,64,48)])

write('classic-monobrush-fill-stroke',esetup()+[rec(38,U(2,0)+I(4,0)+U(0x00ff00)),es(2),erect(8,8,56,56)])
write('classic-monobrush-palette-flood',[es(0x80000008),*ecolors(),mono(usage=1,palette=H(0,1)),palette(3,[(0,255,0),(255,0,0)]),rec(48,U(3)),rec(39,U(2,0,0x00ff00,0)),es(2),erect(0,0,64,64),es(1),rec(30,I(8,8,32,32)),rec(53,I(10,10)+U(0x01000000,1))])

write('classic-patternbrush-palette-select',[es(0x80000008),mono(kind=94,usage=1,palette=H(0,1)),es(1),palette(3,[(0,255,0),(255,0,0)]),rec(48,U(3)),erect(0,0,64,16),rec(50,U(3,0,2)+bytes([0,255,255,0,255,255,0,0])),es(1),erect(0,16,64,32)])
def wdibpattern(indices=(0,1)):
 bmi=U(40)+I(8,-2)+H(1,1)+U(0,8,0,0,0,0)+H(*indices)
 return wr(0x142,H(5,1)+bmi+bytes([0x80,0xa5,0x96,0x69,0x40,0x5a,0x69,0x96]))
def wpalette(colors):return wr(0xf7,H(0x300,len(colors))+b''.join(bytes([r,g,b,0]) for r,g,b in colors))
write('wmf-classic-patternbrush-palette-select',[ws(0x8008),*wcolors(),wdibpattern(),ws(0),wpalette([(0,255,0),(255,0,0)]),wr(0x234,H(1)),wrect(0,0,64,16),wr(0x1e),wpalette([(0,255,255),(255,255,0)]),wr(0x234,H(0,2)),ws(0),wrect(0,16,64,32),wr(0x127,S(-1)),wrect(0,32,64,48),wr(0x139,H(3)),wr(0x37,H(0,3)+bytes([0,0,255,0,0,255,0,0,255,0,255,0])),wdibpattern((0,2)),ws(3),wrect(0,48,64,64)],True)
write('unsupported-classic-patternbrush-emf-missing-palette',eprefix+[mono(usage=1,palette=H(0,1)),es(1),erect(8,8,56,56)])
# Empty ETO_OPAQUE text paints solid explicit BK despite a lazy mono brush;
# the following ordinary FillPath must still use the selected pattern brush.
opaque=rec(84,I(0,0,64,64)+U(2)+F(1,1)+I(0,0)+U(0,76,2)+I(0,0,64,16)+U(0))
write('classic-monobrush-opaque-path',esetup()+[opaque,rec(59),rec(27,I(0,32)),rec(54,I(64,32)),rec(54,I(64,48)),rec(54,I(0,48)),rec(61),rec(60),rec(62,I(0,32,64,48))])
