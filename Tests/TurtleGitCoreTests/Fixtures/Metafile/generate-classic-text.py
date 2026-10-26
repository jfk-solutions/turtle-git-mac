#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Original compact/batched EMF text wire fixtures, no fonts or pictures copied.
MS-EMF 2.3.5.32/33/37 and EmrText 2.2.5. Offsets are RECORD-relative.
Only this family's files are written; existing fixture bytes are preserved.
"""
import pathlib,struct
P=pathlib.Path(__file__).parent
for superseded in ['compact-no-rect-opaque','compact-no-rect-clip','compact-compressed-glyph']:
 (P/('unsupported-classic-text-'+superseded+'.emf')).unlink(missing_ok=True)
U=lambda *v:struct.pack('<'+'I'*len(v),*v)
I=lambda *v:struct.pack('<'+'i'*len(v),*v)
F=lambda *v:struct.pack('<'+'f'*len(v),*v)
H=lambda *v:struct.pack('<'+'H'*len(v),*v)
def pad(b):return b+b'\0'*(-len(b)%4)
def rec(t,b=b''):return U(t,8+len(pad(b)))+pad(b)
def font(charset=0):
 name='Helvetica'.encode('utf-16le')
 lf=I(-18,0,0,0,400)+bytes((0,0,0,charset,0,0,0,0))+name+bytes(64-len(name))
 return rec(82,U(1)+lf+bytes(228))
def setup(align=24,charset=0):return [rec(39,U(2,0,0xffffff,0)),rec(37,U(2)),rec(37,U(0x80000008)),rec(43,I(0,0,96,64)),font(charset),rec(37,U(1)),rec(24,U(0)),rec(25,U(0x00ff00)),rec(18,U(1)),rec(22,U(align))]
def write(name,rs,**kw):
 rs=setup(**kw)+rs+[rec(14,U(0,0,20))]
 header=U(1,88)+I(0,0,96,64)+I(0,0,2540,1693)+U(0x464d4520,0x10000,88+sum(map(len,rs)),len(rs)+1)+H(16,0)+U(0,0,0)+I(960,960,254,254)
 (P/(name+'.emf')).write_bytes(header+b''.join(rs))
def small(text='HH',xy=(8,28),options=0x100,rect=(0,0,96,64),raw=None,count=None,graphics=2,scale=(1,1),tail=b''):
 raw=text.encode('latin1' if options&0x200 else 'utf-16le') if raw is None else raw
 count=len(raw)//(1 if options&0x200 else 2) if count is None else count
 return rec(108,I(*xy)+U(count,options,graphics)+F(*scale)+(b'' if options&0x100 else I(*rect))+raw+tail)
def entry(text='HH',xy=(8,28),dx=None,options=0,rect=(0,0,96,64),raw=None):return dict(text=text,xy=xy,dx=dx,options=options,rect=rect,raw=raw)
def text_records(entries,kind=97,graphics=2,scale=(1,1),gap=0):
 poly=kind in (96,97);ansi=kind in (83,96)
 fixed=40+40*len(entries) if poly else 76
 descriptors=[];payload=bytes(gap);offset=fixed+gap
 for e in entries:
  raw=e['raw'] if e['raw'] is not None else e['text'].encode('cp1252' if ansi else 'utf-16le')
  count=len(raw)//(1 if ansi else 2);stringoff=offset
  payload+=pad(raw);offset+=len(pad(raw));dxoff=offset if e['dx'] is not None else 0
  if dxoff:payload+=I(*e['dx']);offset+=4*len(e['dx'])
  descriptors.append(I(*e['xy'])+U(count,stringoff,e['options'])+I(*e['rect'])+U(dxoff))
 base=I(0,0,96,64)+U(graphics)+F(*scale)+(U(len(entries)) if poly else b'')
 return rec(kind,base+b''.join(descriptors)+payload)
def ext(e,**kw):return text_records([e],kind=84,**kw)
def wide_controls(entries,wire):
 # Measured Windows PolyTextOut treats offDx==0 as the record-start pointer,
 # not natural spacing. Decode the immutable source header into independent
 # ExtTextOutW explicit advances, preserving that unusual playback contract.
 controls=[]
 for e in entries:
  e=dict(e)
  if e['dx'] is None:
   count=len(e['text'].encode('utf-16le'))//2
   if count:e['dx']=struct.unpack('<'+'i'*count,wire[:count*4])
  controls.append(ext(e))
 return controls
def pair(name,actual,control,**kw):
 write('classic-text-'+name,actual,**kw);write('classic-text-'+name+'-control',control,**kw)
for suffix,opt in [('wide',0x100),('small',0x300),('rect',0),('small-rect',0x200)]:pair('compact-'+suffix,[small(options=opt)],[ext(entry())])
pair('compact-low-unicode',[small(text='\x80é',options=0x300)],[ext(entry(text='\x80é'))])
for name,opt in [('clip',4),('opaque',2),('clip-opaque',6)]:pair('compact-'+name,[small(options=opt,rect=(4,4,24,40))],[ext(entry(options=opt,rect=(4,4,24,40)))])
pair('compact-empty-opaque',[small(text='',options=2,rect=(4,4,92,56))],[ext(entry(text='',options=2,rect=(4,4,92,56)))])
pair('compact-updatecp',[rec(27,I(8,28)),small(text='H',xy=(90,50)),small(text='H',xy=(90,50))],[rec(27,I(8,28)),ext(entry(text='H',xy=(90,50))),ext(entry(text='H',xy=(90,50)))],align=25)
pair('compact-world',[rec(35,F(1,0,.25,1,0,0)),small()],[rec(35,F(1,0,.25,1,0,0)),ext(entry())])
for kind,name in [(96,'ansi'),(97,'wide')]:
 for variant,entries in [
  ('natural',[entry(text='HH',xy=(8,28)),entry(text='H',xy=(60,52))]),
  ('dx',[entry(text='HH',dx=(28,28)),entry(text='H',xy=(64,28),dx=(12,))]),
  ('pdy',[entry(text='HHH',dx=(28,0,28,8,28,0),options=0x2000)]),
  ('clip-opaque',[entry(text='HHH',options=6,rect=(4,4,48,40)),entry(text='H',xy=(64,52))]),
  ('empty',[entry(text=''),entry(text='H')])]:
  pair('poly-'+name+'-'+variant,[text_records(entries,kind=kind,gap=8)],wide_controls(entries,text_records(entries,kind=kind,gap=8)))
 entries=[entry(text='H',xy=(90,50),dx=(28,)),entry(text='H',xy=(90,50),dx=(28,))]
 pair('poly-'+name+'-updatecp',[rec(27,I(8,28)),text_records(entries,kind=kind)],[rec(27,I(8,28))]+[ext(e) for e in entries],align=25)
for kind,name in [(83,'ext-ansi'),(96,'poly-ansi')]:
 entries=[entry(text='€é',dx=(28,28))]
 pair(name+'-cp1252',[text_records(entries,kind=kind)],[ext(e) for e in entries])
 pair(name+'-ascii-default',[text_records([entry()],kind=kind)],wide_controls([entry()],text_records([entry()],kind=kind)) if kind==96 else [ext(entry())],charset=1)
pair('poly-zero', [text_records([])], [])
# Counterpart records use no compact flags. Deliberately malformed framing lives
# inside a valid outer EMF, so refusal cannot be attributed to an outer header.
def bad(name,r,**kw):write('unsupported-classic-text-'+name,[r],**kw)
def mutate(record,offset,value):return record[:offset]+U(value)+record[offset+4:]
bad('compact-truncated-text',small(raw=b'H\0',count=5))
bad('compact-missing-rectangle',rec(108,I(8,28)+U(1,0,2)+F(1,1)+b'H\0'))
bad('compact-trailing-data',small(tail=bytes(8)))
pair('compact-no-rect-opaque',[small(options=0x102)],[ext(entry())])
pair('compact-no-rect-clip',[small(options=0x104)],[ext(entry())])
bad('compact-pdy',small(options=0x2100))
bad('compact-option',small(options=0x80000100))
bad('compact-graphics',small(graphics=3))
bad('compact-scale',small(graphics=1,scale=(float('nan'),1)))
bad('compact-count',small(raw=b'',count=32769))
bad('compact-unpaired-surrogate',small(raw=b'\0\xd8'))
p=text_records([entry(),entry(text='H',xy=(60,28))])
for name,off,value in [('poly-negative-count',36,0xffffffff),('poly-array-truncated',36,20),('poly-string-before-array',52,40),('poly-string-after-record',52,len(p)+4),('poly-dx-before-array',76,40),('poly-dx-after-record',76,len(p)+4),('poly-unknown-option',56,0x80000000),('poly-compact-option',56,0x200),('poly-second-string-after-record',92,len(p)+4),('poly-unit-budget',48,32769)]:bad(name,mutate(p,off,value))
for kind,name in [(83,'ext'),(96,'poly')]:
 bad(name+'-ansi-glyph',text_records([entry(raw=b'HH',options=0x10)],kind=kind))
 bad(name+'-ansi-default-high',text_records([entry(raw=b'\x80')],kind=kind),charset=1)
 bad(name+'-ansi-unknown-charset',text_records([entry(raw=b'\xe9')],kind=kind),charset=2)
# Nine legal 32768-unit descriptors exceed the shared262144-unit reservation;
# each is individually legal. Distinct records also share the same reservation.
large=entry(text=' '*32768,dx=(0,)*32768)
bad('poly-aggregate-budget',text_records([large]*9))
write('unsupported-classic-text-compact-aggregate-budget',[small(text=' '*32768)]*9)
# Path mode consumes glyph outlines rather than painting immediately. The green
# marker after restore witnesses both clip and current text/color restoration.
for family,actual,control in [('compact',small(),ext(entry())),('poly',text_records([entry()]),wide_controls([entry()],text_records([entry()]))[0])]:
 pair(family+'-path',[rec(59),actual,rec(60),rec(37,U(0x80000004)),rec(62,I(0,0,96,64))],[rec(59),control,rec(60),rec(37,U(0x80000004)),rec(62,I(0,0,96,64))])
 pair(family+'-restore',[rec(33),rec(30,I(0,0,24,40)),actual,rec(34,I(-1)),rec(39,U(3,0,0x00ff00,0)),rec(37,U(3)),rec(43,I(80,48,92,60))],[rec(33),rec(30,I(0,0,24,40)),control,rec(34,I(-1)),rec(39,U(3,0,0x00ff00,0)),rec(37,U(3)),rec(43,I(80,48,92,60))])
pair('compact-compatible',[rec(35,F(2,0,0,1,0,0)),small(graphics=1,scale=(2.5,2.5))],[rec(35,F(2,0,0,1,0,0)),ext(entry(),graphics=1,scale=(2.5,2.5))])
pair('poly-compatible',[rec(35,F(2,0,0,1,0,0)),text_records([entry(text='HH',dx=(20,20))],graphics=1,scale=(2.5,2.5))],[rec(35,F(2,0,0,1,0,0)),ext(entry(text='HH',dx=(20,20)),graphics=1,scale=(2.5,2.5))])
# Fixed LOGFONT charset mappings, paired against literal UTF16, not locale state.
for charset,encoding,text in [(238,'cp1250','ŁH'),(204,'cp1251','ЯH'),(161,'cp1253','ΩH'),(162,'cp1254','ĞH'),(177,'cp1255','אH'),(178,'cp1256','عH'),(186,'cp1257','ĀH'),(163,'cp1258','đH'),(222,'cp874','กH')]:
 for kind,label in [(83,'ext'),(96,'poly')]:
  a=entry(raw=text.encode(encoding),dx=(28,28));w=entry(text=text,dx=(28,28))
  pair(label+'-charset-'+str(charset),[text_records([a],kind=kind)],[ext(w)],charset=charset)
for charset,encoding,text in [(128,'shift_jis','あH'),(129,'cp949','갂H'),(134,'gbk','你H'),(136,'big5','你H')]:
 raw=text.encode(encoding);assert len(raw)==3
 for kind,label in [(83,'ext'),(96,'poly')]:
  pair(label+'-dbcs-'+str(charset),[text_records([entry(raw=raw,dx=(12,16,28))],kind=kind)],[ext(entry(text=text,dx=(28,28)))],charset=charset)
  pair(label+'-dbcs-pdy-'+str(charset),[text_records([entry(raw=raw,dx=(12,2,16,4,28,0),options=0x2000)],kind=kind)],[ext(entry(text=text,dx=(28,6,28,0),options=0x2000))],charset=charset)
 for suffix,raw in [('lead-truncated',raw[:1]),('trail-invalid',raw[:1]+b'\x20')]:bad('dbcs-'+str(charset)+'-'+suffix,text_records([entry(raw=raw)],kind=96),charset=charset)
for kind,label in [(83,'ext'),(96,'poly')]:
 bad(label+'-symbol-ascii',text_records([entry()],kind=kind),charset=2)
 bad(label+'-ansi-oem-high',text_records([entry(raw=b'\xe9')],kind=kind),charset=255)
bad('poly-no-rect',text_records([entry(options=0x100)]))
for kind,label in [(96,'ansi'),(97,'wide')]:
 entries=[entry(text='H'),entry(text='H')];wire=text_records(entries,kind=kind)
 pair('poly-'+label+'-offdx-zero-updatecp',[rec(27,I(8-kind,28)),wire],[rec(27,I(8-kind,28))]+wide_controls(entries,wire),align=25)
