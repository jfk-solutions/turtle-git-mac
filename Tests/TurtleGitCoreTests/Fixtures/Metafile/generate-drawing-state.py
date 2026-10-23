#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Original deterministic classic drawing-state records; never runs a renderer.

EMF stock18/19 defaults only: genuine recorders encode later DC color changes as
ordinary create/select replacements, not nonexistent EMR DC-color setters.
The 20-color DEFAULT_PALETTE is the explicitly chosen Windows common-display
logical playback profile, not a claim about every physical device palette.
"""
import pathlib, struct
P=pathlib.Path(__file__).parent
U=lambda *v:struct.pack('<'+'I'*len(v),*v)
I=lambda *v:struct.pack('<'+'i'*len(v),*v)
H=lambda *v:struct.pack('<'+'H'*len(v),*v)
S=lambda *v:struct.pack('<'+'h'*len(v),*v)
F=lambda *v:struct.pack('<'+'f'*len(v),*v)
PROFILE=[(0,0,0),(128,0,0),(0,128,0),(128,128,0),(0,0,128),(128,0,128),(0,128,128),(192,192,192),(192,220,192),(166,202,240),(255,251,240),(160,160,164),(128,128,128),(255,0,0),(0,255,0),(255,255,0),(0,0,255),(255,0,255),(0,255,255),(255,255,255)]
def rec(t,b=b''):
 b+=b'\0'*(-len(b)%4);return U(t,len(b)+8)+b
def wr(t,b=b''):
 b+=b'\0'*(len(b)%2);return U((len(b)+6)//2)+H(t)+b
def write(name,records,w=False):
 if w:
  records=[wr(0x20b,S(0,0)),wr(0x20c,S(64,64)),*records,wr(0)]
  place=U(0x9ac6cdd7)+H(0)+S(0,0,64,64)+H(96)+U(0);checksum=0
  for n in struct.unpack('<10H',place):checksum^=n
  data=place+H(checksum)+H(1,9,0x300)+U((18+sum(map(len,records)))//2)+H(32)+U(max(len(r)//2 for r in records))+H(0)+b''.join(records)
 else:
  records=[*records,rec(14,U(0,0,20))]
  data=U(1,88)+I(0,0,64,64)+I(0,0,1693,1693)+U(0x464d4520,0x10000,88+sum(map(len,records)),len(records)+1)+H(32,0)+U(0,0,0)+I(960,960,254,254)+b''.join(records)
 (P/(name+('.wmf' if w else '.emf'))).write_bytes(data)
def sel(h):return rec(37,U(h))
def brush(h,c):return rec(39,U(h,0,c,0))
def pen(h,c,width=2):return rec(38,U(h,0)+I(width,0)+U(c))
def rect(x,y,w,h):return rec(43,I(x,y,x+w,y+h))
def line(x,y,x2,y2):return [rec(27,I(x,y)),rec(54,I(x2,y2))]
def stockline(x,y,x2,y2):return [rec(33),rec(35,F(1,0,0,1,0,.5)),*line(x,y,x2,y2),rec(34,I(-1))]
def base():return [sel(0x80000008),brush(1,0xff0000),sel(1),rect(0,0,64,64)]
def objects():return [brush(2,255),pen(3,255),brush(10,0xffffff),pen(11,0,1)]
def stock_vector(control):
 white=10 if control else 0x80000012;black=11 if control else 0x80000013
 return base()+objects()+[sel(white),rect(4,4,20,16),sel(black),*stockline(4,28,24,28),sel(2),rect(36,4,20,16),sel(3),*line(36,28,56,28),rec(33),sel(white),sel(black),rec(24,U(0x00ff00)),rec(25,U(255)),rect(4,36,20,16),*stockline(4,60,24,60),rec(34,I(-1)),rect(36,36,20,16),*line(36,60,56,60)]
def rg(x,y,w,h):return U(32,1,1,16)+I(x,y,x+w,y+h)+I(x,y,x+w,y+h)
def fill_region(handle):
 data=rg(4,4,20,20);return rec(71,I(4,4,24,24)+U(len(data),handle)+data)
def pat(x,y,w,h):return rec(76,I(x,y,x+w,y+h)+I(x,y,w,h)+U(0xf00021)+I(0,0)+F(1,0,0,1,0,0)+U(0,0,0,0,0,0))
def stock_consumers(control):
 white=10 if control else 0x80000012;black=11 if control else 0x80000013
 return base()+objects()+[sel(2),fill_region(white),rect(36,4,20,20),sel(3),rec(33),sel(white),sel(black),pat(4,36,20,20),rec(33),rec(30,I(36,36,60,56)),rec(53,I(44,44)+U(0xff0000,1)),rec(34,I(-1)),*stockline(4,48,24,48),rec(34,I(-1)),*line(36,60,56,60)]
for name,scene in [('stock-vector',stock_vector),('stock-consumers',stock_consumers)]:
 for control in [False,True]:write('classic-dc-'+name+('-control' if control else ''),scene(control))
def pal(handle,entries,w=False,flags=0):
 body=H(0x300,len(entries))+b''.join(bytes([r,g,b,flags]) for r,g,b in entries)
 return wr(0xf7,body) if w else rec(49,U(handle)+body)
def selectpal(handle,w=False):return wr(0x234,H(handle)) if w else rec(48,U(handle))
def save(w=False):return wr(0x1e) if w else rec(33)
def restore(w=False):return wr(0x127,S(-1)) if w else rec(34,I(-1))
def palette_set(handle,entries,w=False):
 data=b''.join(bytes([r,g,b,0]) for r,g,b in entries)
 return wr(0x37,H(0,len(entries))+data) if w else rec(50,U(handle,0,len(entries))+data)
def raster(indices,logical,*,x=2,y=2,w=60,h=48,sourcew=5,sourceh=4,colors=PROFILE,wmf=False):
 stride=(sourcew+3)//4*4
 bits=b''.join(bytes(indices[row*sourcew:(row+1)*sourcew])+b'\0'*(stride-sourcew) for row in range(sourceh))
 table=b''.join(H(n) for n in range(len(colors))) if logical else b''.join(bytes([b,g,r,0]) for r,g,b in colors)
 bmi=U(40)+I(sourcew,-sourceh)+H(1,8)+U(0,len(bits),0,0,len(colors),0)+table
 usage=int(logical)
 if wmf:return wr(0xf43,U(0xcc0020)+H(usage)+S(sourceh,sourcew,0,0,h,w,y,x)+bmi+bits)
 return rec(81,I(x,y,x+w,y+h)+I(x,y,0,0,sourcew,sourceh)+U(80,len(bmi),80+len(bmi),len(bits),usage,0xcc0020)+I(w,h)+bmi+bits)
def profile(control,w=False):
 out=[raster(list(range(20)),not control,wmf=w)]
 default=0x800f if w else 0x8000000f
 # Select a private palette, then DEFAULT explicitly. Mutating DEFAULT is a
 # successful no-op on read-only stock state; later indexed use stays profile.
 out+=[pal(1,[(0,255,0)],w),selectpal(0 if w else 1,w),selectpal(default,w)]
 out+=[palette_set(default,[(0,255,0)],w),raster([0],not control,x=24,y=54,w=6,h=8,sourcew=1,sourceh=1,colors=[(0,0,0)],wmf=w)]
 if w:
  out += [wr(0x12d,H(0x8008)),wr(0x2fc,H(0)+U(255 if control else 0x0100000d)+H(0)),wr(0x12d,H(1)),wr(0x41b,S(62,22,54,4)),wr(0x2fa,H(0)+S(2,0)+U(0xff0000 if control else 0x01000010)),wr(0x12d,H(2)),wr(0x214,S(58,32)),wr(0x213,S(58,60))]
 else:out += [sel(0x80000008),brush(2,255 if control else 0x0100000d),sel(2),rect(4,54,18,8),pen(3,0xff0000 if control else 0x01000010),sel(3),*line(32,58,60,58)]
 return out
def palette_state(control,w=False):
 default=0x800f if w else 0x8000000f;custom=0 if w else 1
 out=[pal(1,[(255,0,0)],w),selectpal(custom,w),raster([0],not control,x=4,y=4,w=20,h=20,sourcew=1,sourceh=1,colors=[(255,0,0)],wmf=w),save(w),selectpal(default,w),save(w)]
 # A saved DC still selects the custom object: DeleteObject is ignored.
 if not control:out += [wr(0x1f0,H(custom)) if w else rec(40,U(custom))]
 # Change the same custom palette object while saved; restore must retain its
 # live identity. WMF modifies the selected palette; EMF names it explicitly.
 if w:out += [selectpal(custom,w)]
 out += [palette_set(custom,[(0,0,255)],w),restore(w)]
 out += [raster([0],not control,x=36,y=4,w=20,h=20,sourcew=1,sourceh=1,colors=[(0,0,0)],wmf=w),restore(w),raster([0],not control,x=4,y=36,w=20,h=20,sourcew=1,sourceh=1,colors=[(0,0,255)],wmf=w)]
 # Delete an unselected custom palette; selecting DEFAULT afterwards cannot
 # reuse or mutate the deleted object's previous entries.
 out += [selectpal(default,w),wr(0x1f0,H(custom)) if w else rec(40,U(custom)),raster([0],not control,x=36,y=36,w=20,h=20,sourcew=1,sourceh=1,colors=[(0,0,0)],wmf=w)]
 return out
for w in [False,True]:
 for name,scene in [('profile',profile),('state',palette_state)]:
  for control in [False,True]:write(('wmf-' if w else 'classic-')+'default-palette-'+name+('-control' if control else ''),scene(control,w),w)
 # Default palette entry20 is outside the explicit20 logical profile.
 write(('unsupported-drawing-state-wmf-' if w else 'unsupported-drawing-state-')+'palette-index', [raster([20],True,sourcew=1,sourceh=1,colors=[(0,0,0)]*21,wmf=w)],w)
 # PC_EXPLICIT references an unknown hardware palette index; no device guess.
 write(('unsupported-drawing-state-wmf-' if w else 'unsupported-drawing-state-')+'hardware-entry',[pal(1,[(1,0,0)],w,flags=2),selectpal(0 if w else 1,w),raster([0],True,sourcew=1,sourceh=1,colors=[(0,0,0)],wmf=w)],w)
for stock in [18,19]:write('unsupported-drawing-state-wmf-stock-'+str(stock),[wr(0x12d,H(0x8000|stock)),wr(0x41b,S(24,24,4,4))],True)

# PALETTEINDEX object colors are resolved at paint time, not creation time.
# The second palette changes the same selected ordinary/extended/hatch/text
# objects. Controls replace them with independently authored ordinary RGB.
def font(handle=8):
 name='Helvetica'.encode('utf-16le')
 lf=I(-18,0,0,0,400)+bytes((0,0,0,1,0,0,0,0))+name+bytes(64-len(name))
 return rec(82,U(handle)+lf+bytes(228))
def text(y):
 raw='H'.encode('utf-16le')+b'\0\0'
 return rec(84,I(0,0,64,64)+U(2)+F(1,1)+I(44,y)+U(1,76,0)+I(0,0,64,64)+U(0)+raw)
def color_consumers(control):
 out=[sel(0x80000008),font(),rec(18,U(1)),rec(22,U(24)),pal(1,[(255,0,0),(0,0,255)]),pal(2,[(0,255,0),(255,255,0)])]
 for stage,offset in enumerate([0,32]):
  out += [selectpal(stage+1)]
  if stage==0 or control:
   basehandle=10+stage*5 if control else 3
   fill=(255 if stage==0 else 0x00ff00) if control else 0x01000000
   stroke=(0xff0000 if stage==0 else 0x00ffff) if control else 0x01000001
   out += [brush(basehandle,fill),pen(basehandle+1,stroke),rec(95,U(basehandle+2,0,0,0,0,0x12200,4,0,stroke,0,0)),rec(39,U(basehandle+3,2,fill,4)),rec(24,U(fill))]
  out += [sel(0x80000008),sel(basehandle),rect(2,2+offset,12,10),sel(basehandle+1),*line(2,16+offset,14,16+offset),sel(basehandle+2),*line(2,24+offset,14,24+offset),sel(0x80000008),sel(basehandle+3),rect(20,2+offset,16,24),sel(8),text(24+offset)]
 return out
for control in [False,True]:write('classic-palette-color-consumers'+('-control' if control else ''),color_consumers(control))

# A logical brush may precede its usable palette. Selection/SaveDC/RestoreDC or
# changing unrelated text/background attributes must not resolve paint color.
def deferred_palette(control):
 colors=[(0,0,0)]*25+[(0,255,255)]
 return [sel(0x80000008),brush(1,0xffff00 if control else 0x01000019),sel(1),rec(33),rec(34,I(-1)),rec(24,U(0)),rec(25,U(0xffffff)),pal(2,colors),selectpal(2),rect(4,4,24,24),brush(3,255 if control else 0x010003e8),sel(3)]
for control in [False,True]:write('classic-deferred-palette-brush'+('-control' if control else ''),deferred_palette(control))
write('unsupported-drawing-state-painted-unresolved-brush',base()+[brush(2,0x010003e8),sel(2),rect(4,4,24,24)])
