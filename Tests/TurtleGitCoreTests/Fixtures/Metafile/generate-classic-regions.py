#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Original classic region/frame/flood records, independent of renderer code.
All paintings use a 64x64 device canvas. No helper/test process is executed.
"""
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
  value=place+H(check)+H(1,9,0x300)+U((18+sum(map(len,rs)))//2)+H(16)+U(max(len(r)//2 for r in rs))+H(0)+b''.join(rs)
 else:
  rs=[*rs,rec(14,U(0,0,20))]
  value=U(1,88)+I(0,0,64,64)+I(0,0,1693,1693)+U(0x464d4520,0x10000,88+sum(map(len,rs)),len(rs)+1)+H(32,0)+U(0,0,0)+I(960,960,254,254)+b''.join(rs)
 (P/(n+('.wmf' if wmf else '.emf'))).write_bytes(value)
def brush(h,c,style=0,hatch=0):return rec(39,U(h,style,c,hatch))
def sel(h):return rec(37,U(h))
def rect(l,t,r,b):return rec(43,I(l,t,r,b))
def setup():return [sel(0x80000008),brush(1,255),brush(2,0xff0000),brush(3,0),sel(2)]
def bounds(rs):return (min(r[0] for r in rs),min(r[1] for r in rs),max(r[2] for r in rs),max(r[3] for r in rs)) if rs else (0,0,0,0)
def region(rs):return U(32,1,len(rs),16*len(rs))+I(*bounds(rs))+b''.join(I(*r) for r in rs)
def regionop(kind,rs,handle=1,width=3,height=5):
 rg=region(rs);fixed=I(0,0,64,64)+U(len(rg))
 if kind in [71,72]:fixed+=U(handle)
 if kind==72:fixed+=I(width,height)
 return rec(kind,fixed+rg)
L=[(8,8,32,24),(8,24,56,56)]
HOLE=[(8,8,56,16),(8,16,16,48),(48,16,56,48),(8,48,56,56)]
ISLANDS=[(8,8,24,24),(40,40,56,56)]
write('classic-region-fill-preserve',setup()+[regionop(71,L),rect(48,0,64,6)])
write('classic-region-paint-current',setup()+[regionop(74,L)])
write('classic-region-invert',setup()+[sel(1),rect(0,0,64,64),regionop(73,L)])
for n,rs in [('union',L),('hole',HOLE),('islands',ISLANDS)]:write('classic-region-frame-'+n,setup()+[regionop(72,rs),rect(48,0,64,6)])
write('classic-region-frame-negative',setup()+[regionop(72,L,width=-3,height=-5),rect(48,0,64,6)])
write('classic-region-frame-zero',setup()+[regionop(72,L,width=0,height=0)])
write('classic-region-frame-zero-x',setup()+[regionop(72,[(8,8,56,56)],width=0,height=5)])
write('classic-region-frame-zero-y',setup()+[regionop(72,[(8,8,56,56)],width=3,height=0)])
write('classic-region-empty',setup()+[regionop(71,[]),regionop(72,[]),regionop(73,[]),regionop(74,[])])
write('classic-region-transform-restore',setup()+[rec(33),rec(30,I(0,0,32,64)),rec(35,F(2,0,0,1,0,0)),regionop(71,[(4,8,24,24)]),rec(34,I(-1)),regionop(74,[(40,40,56,56)])])
write('classic-region-frame-rop2',setup()+[rec(20,U(7)),regionop(72,[(8,8,56,56)])])
def enclosure():return [sel(3),rect(8,8,56,10),rect(8,54,56,56),rect(8,10,10,54),rect(54,10,56,54),rect(30,10,34,54),sel(2),rect(20,20,24,24),sel(1)]
def flood(mode=1,color=0xffffff,x=16,y=16):return rec(53,I(x,y)+U(color,mode))
for n,mode,color in [('surface',1,0xffffff),('border',0,0)]:write('classic-flood-'+n,setup()+enclosure()+[flood(mode,color)])
for n,op in [('surface-mismatch',flood(1,0xff0000)),('border-seed',flood(0,0,8,8)),('outside',flood(1,0xffffff,80,80)),('invalid-color',flood(1,0xffffffff))]:write('classic-flood-noop-'+n,setup()+enclosure()+[op])
write('classic-flood-noop-clipped',setup()+enclosure()+[rec(30,I(8,8,24,24)),flood(x=4,y=4)])
write('classic-flood-noop-hollow',setup()+enclosure()+[brush(4,0,1),sel(4),flood()])
# A classic AlphaBlend creates actual destination colors before flood capture.
# Premultiplied red128/alpha128 over opaque white gives RGB(255,127,127).
def half_red():
 bmi=U(40)+I(2,-2)+H(1,32)+U(0,16,0,0,0,0);bits=bytes([0,0,128,128])*4
 return rec(114,I(0,0,64,64)+I(8,8,16,16)+U(0x01ff0000)+I(0,0)+F(1,0,0,1,0,0)+U(0,0,108,40,148,16)+I(2,2)+bmi+bits)
write('classic-flood-alpha-destination',setup()+[half_red(),sel(2),flood(color=0x7f7fff,x=16,y=16)])
write('classic-flood-four-connected',setup()+[sel(3),rect(0,0,64,64),brush(4,0xffffff),sel(4),rect(10,10,11,11),rect(11,11,12,12),sel(1),flood(x=10,y=10)])
write('classic-flood-clip',setup()+[sel(1),rec(30,I(8,8,24,24)),flood()])
write('classic-flood-hatch',setup()+enclosure()+[brush(4,255,2,4),sel(4),flood()])
write('classic-flood-rop2',setup()+[brush(4,0xffffff),sel(4),rec(20,U(7)),rec(30,I(8,8,24,24)),flood()])
write('classic-flood-transform-restore',setup()+[sel(1),rec(33),rec(30,I(8,8,24,24)),rec(35,F(2,0,0,2,0,0)),flood(x=8,y=8),rec(34,I(-1)),sel(2),rect(40,40,56,56)])
# A valid earlier rectangle ensures malformed records never return partial paint.
prefix=setup()+[rect(0,0,6,6)]
bad={
 'header-short':rec(71,I(0,0,64,64)+U(12,1)+b'\0'*12),
 'header-size':rec(71,I(0,0,64,64)+U(48,1)+U(28,1,1,16)+I(8,8,24,24)+I(8,8,24,24)),
 'header-type':rec(71,I(0,0,64,64)+U(48,1)+U(32,2,1,16)+I(8,8,24,24)+I(8,8,24,24)),
 'count-overrun':rec(71,I(0,0,64,64)+U(48,1)+U(32,1,2,32)+I(8,8,24,24)+I(8,8,24,24)),
 'rect-inverted':regionop(71,[(24,8,8,24)]),
 'fill-brush':regionop(71,L,handle=15),
 'frame-brush':regionop(72,L,handle=15),
 'flood-mode':flood(2),
 'flood-short':rec(53,I(16,16)+U(0xffffff)),
}
for n,value in bad.items():write('unsupported-classic-region-'+n,prefix+[value])
# WMF recorder/playback-compatible argument order (Wine metadc.c/metafile.c):
# Fill = Brush,Region; Frame = Height,Width,Brush,Region. RegionSize includes
# function WORD, maxScan counts x coordinates; next/count fields are ignored.
def wb(c,style=0,hatch=0):return wr(0x2fc,H(style)+U(c)+H(hatch))
def ws(n):return wr(0x12d,H(n))
def wrect(l,t,r,b):return wr(0x41b,S(b,r,t,l))
def wsetup():return [ws(0x8008),wb(255),wb(0xff0000),wb(0),ws(1)]
def wregion(rs):
 bands={}
 for l,t,r,b in rs:bands.setdefault((t,b),[]).extend([l,r])
 scans=b''.join(H(len(xs))+S(t,b,*xs)+H(len(xs)) for (t,b),xs in sorted(bands.items()))
 fixed=H(0x1234,6)+U(0x87654321)+S(24+len(scans),len(bands),max((len(xs) for xs in bands.values()),default=0))+S(*bounds(rs))
 return wr(0x6ff,fixed+scans)
def wop(kind,region=3,brush=0,w=3,h=5):
 return wr(kind,H(brush,region) if kind==0x228 else S(h,w)+H(brush,region) if kind==0x429 else H(region))
for name,kind in [('fill-preserve',0x228),('paint-current',0x12b),('frame-union',0x429)]:
 write('wmf-classic-region-'+name,wsetup()+[wregion(L),wop(kind),wrect(48,0,64,6)],True)
write('wmf-classic-region-invert',wsetup()+[ws(0),wrect(0,0,64,64),wregion(L),wop(0x12a)],True)
for name,rs in [('hole',HOLE),('islands',ISLANDS)]:write('wmf-classic-region-frame-'+name,wsetup()+[wregion(rs),wop(0x429)],True)
write('wmf-classic-region-negative',wsetup()+[wregion([(-8,-8,16,16)]),wop(0x228)],True)
write('wmf-classic-region-slot-reuse',wsetup()+[wregion(L),wop(0x228),wr(0x1f0,H(3)),wb(0x00ff00),ws(3),wrect(40,0,56,6)],True)
def wenclosure():return [ws(2),wrect(8,8,56,10),wrect(8,54,56,56),wrect(8,10,10,54),wrect(54,10,56,54),wrect(30,10,34,54),ws(1),wrect(20,20,24,24),ws(0)]
def wflood(mode=1,color=0xffffff,x=16,y=16,old=False):return wr(0x419 if old else 0x548,(b'' if old else H(mode))+U(color)+S(y,x))
for name,mode,color,old in [('surface',1,0xffffff,False),('border',0,0,False),('legacy-border',0,0,True)]:write('wmf-classic-flood-'+name,wsetup()+wenclosure()+[wflood(mode,color,old=old)],True)
write('wmf-classic-flood-clip',wsetup()+[ws(0),wr(0x416,S(24,24,8,8)),wflood()],True)
write('wmf-classic-flood-hatch',wsetup()+wenclosure()+[wb(255,2,4),ws(3),wflood()],True)
wrgn=wregion(L)
# Regenerate framing after independent field corruption; do not rely on malformed
# record-size envelopes to hide region-object validation errors.
def patch_body(record,offset,value):return record[:6+offset]+value+record[6+offset+len(value):]
wbad={
 'object-type':patch_body(wrgn,2,H(7)),
 'scan-count':patch_body(wrgn,10,S(10)),
 'odd-count':patch_body(wrgn,22,H(3)),
 'count2':patch_body(wrgn,32,H(4)),
 'scan-truncated':wr(0x6ff,wrgn[6:-2]),
 'missing-region':wop(0x12b,region=15),
 'wrong-region-object':wop(0x12b,region=0),
 'wrong-fill-brush':wop(0x228,brush=3),
 'flood-mode':wflood(2),
 'flood-short':wr(0x548,H(1)+U(0xffffff)+S(16)),
}
for n,value in wbad.items():write('unsupported-wmf-classic-region-'+n,wsetup()+[wrect(0,0,6,6),wrgn,value],True)
write('unsupported-wmf-classic-region-deleted',wsetup()+[wrgn,wr(0x1f0,H(3)),wop(0x12b)],True)
# SelectClipRgn copies device coordinates using the initial metafile mapping;
# zero is NULL, while region object slot0 remains valid for FillRegion.
clip_region=wregion([(8,8,24,24)])
select_clip=wr(0x12c,H(3))
write('wmf-classic-region-select-clip-copy-device',wsetup()+[clip_region,wr(0x20c,S(32,32)),select_clip,wr(0x1f0,H(3)),wb(0x00ff00),wr(0x20c,S(64,64)),ws(3),wrect(0,0,64,64)],True)
write('wmf-classic-region-select-clip-null',wsetup()+[clip_region,select_clip,wr(0x1f0,H(3)),wr(0x12c,H(0)),ws(0),wrect(0,0,64,64)],True)
write('wmf-classic-region-select-clip-restored',wsetup()+[clip_region,select_clip,wr(0x1e),wr(0x1f0,H(3)),wr(0x12c,H(0)),ws(1),wrect(0,0,64,64),wr(0x127,S(-1)),ws(0),wrect(0,0,64,64)],True)
write('wmf-classic-region-zero-index',[ws(0x8008),wregion(L),wb(255),wop(0x228,region=0,brush=1)],True)
for name,value in [('select-clip-object',wr(0x12c,H(1))),('select-clip-missing',wr(0x12c,H(15))),('select-clip-short',wr(0x12c))]:
 write('unsupported-wmf-classic-region-'+name,wsetup()+[wrect(0,0,6,6),value],True)
# Selected device clips must remain outside subsequent logical transforms for
# region geometry AND bitmap transfer coverage (not merely ordinary rectangles).
write('wmf-classic-region-select-clip-transformed-region',wsetup()+[clip_region,wr(0x12c,H(3)),wr(0x20c,S(32,32)),wregion([(0,0,32,32)]),wop(0x228,region=4,brush=0),wregion([(4,4,12,12)]),wop(0x429,region=5,brush=1,w=1,h=2)],True)
bitmap=U(40)+I(1,-1)+H(1,32)+U(0,4,0,0,0,0)+bytes([0,0,255,0])
write('wmf-classic-region-select-clip-transformed-bitmap',wsetup()+[clip_region,wr(0x12c,H(3)),wr(0x20c,S(32,32)),wr(0x0b41,U(0xcc0000)+S(1,1,0,0,32,32,0,0)+bitmap)],True)
write('wmf-classic-region-select-empty',wsetup()+[wregion([]),wr(0x12c,H(3)),ws(0),wrect(0,0,64,64)],True)
write('wmf-classic-region-select-combined-restore',wsetup()+[wregion([(8,8,56,56)]),wr(0x12c,H(3)),wr(0x20c,S(32,32)),wr(0x416,S(20,20,4,4)),wr(0x415,S(12,12,8,8)),wr(0x1e),wr(0x12c,H(0)),ws(1),wrect(0,0,32,32),wr(0x127,S(-1)),ws(0),wrect(0,0,32,32)],True)
