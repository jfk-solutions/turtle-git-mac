#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Original WMF text wires and independently framed Unicode EMF controls.
No helper or test process is run; existing corpus is never rewritten.
"""
import pathlib,struct
P=pathlib.Path(__file__).parent
(P/'unsupported-wmf-text-textout-missing-odd-pad.wmf').unlink(missing_ok=True)
U=lambda *v:struct.pack('<'+'I'*len(v),*v)
I=lambda *v:struct.pack('<'+'i'*len(v),*v)
H=lambda *v:struct.pack('<'+'H'*len(v),*v)
S=lambda *v:struct.pack('<'+'h'*len(v),*v)
F=lambda *v:struct.pack('<'+'f'*len(v),*v)
def pad(b,n=4):return b+b'\0'*(-len(b)%n)
def wr(t,b=b''):return U((len(pad(b,2))+6)//2)+H(t)+pad(b,2)
def er(t,b=b''):return U(t,len(pad(b))+8)+pad(b)
def font_values(height=-18,width=0,angle=0,orientation=0,weight=400,italic=0,underline=0,strike=0,charset=0,face='Helvetica'):
 return dict(height=height,width=width,angle=angle,orientation=orientation,weight=weight,italic=italic,underline=underline,strike=strike,charset=charset,face=face)
def wf(**kw):
 p=font_values(**kw);name=p['face'].encode('ascii');assert len(name)<32
 return wr(0x2fb,S(p['height'],p['width'],p['angle'],p['orientation'],p['weight'])+bytes((p['italic'],p['underline'],p['strike'],p['charset'],0,0,0,0))+name+bytes(32-len(name)))
def ef(**kw):
 p=font_values(**kw);name=p['face'].encode('utf-16le');assert len(name)<64
 return er(82,U(1)+I(p['height'],p['width'],p['angle'],p['orientation'],p['weight'])+bytes((p['italic'],p['underline'],p['strike'],p['charset'],0,0,0,0))+name+bytes(64-len(name))+bytes(228))
def wsetup(align=24,bk=1,**kw):return [wr(0x2fc,H(0)+U(0xffffff)+H(0)),wr(0x12d,H(0)),wr(0x12d,H(0x8008)),wr(0x41b,S(64,96,0,0)),wf(**kw),wr(0x12d,H(1)),wr(0x209,U(0)),wr(0x201,U(0x00ff00)),wr(0x102,H(bk)),wr(0x12e,H(align))]
def esetup(align=24,bk=1,**kw):return [er(39,U(2,0,0xffffff,0)),er(37,U(2)),er(37,U(0x80000008)),er(43,I(0,0,96,64)),ef(**kw),er(37,U(1)),er(24,U(0)),er(25,U(0x00ff00)),er(18,U(bk)),er(22,U(align))]
def wmfb(rs,setup=True,**kw):
 rs=[wr(0x20b,S(0,0)),wr(0x20c,S(64,96))]+(wsetup(**kw) if setup else [])+rs+[wr(0)]
 place=U(0x9ac6cdd7)+H(0)+S(0,0,96,64)+H(96)+U(0);check=0
 for n in struct.unpack('<10H',place):check^=n
 return place+H(check)+H(1,9,0x300)+U((18+sum(map(len,rs)))//2)+H(32)+U(max(len(r)//2 for r in rs))+H(0)+b''.join(rs)
def emfb(rs,**kw):
 rs=esetup(**kw)+rs+[er(14,U(0,0,20))]
 return U(1,88)+I(0,0,96,64)+I(0,0,2540,1693)+U(0x464d4520,0x10000,88+sum(map(len,rs)),len(rs)+1)+H(32,0)+U(0,0,0)+I(960,960,254,254)+b''.join(rs)
def wt(raw=b'HH',xy=(8,28),padbyte=0):return wr(0x521,H(len(raw))+raw+(bytes((padbyte,)) if len(raw)%2 else b'')+S(xy[1],xy[0]))
def wx(raw=b'HH',xy=(8,28),dx=None,options=0,rect=(4,4,48,40),padbyte=0):
 return wr(0xa32,S(xy[1],xy[0],len(raw))+H(options)+(S(*rect) if options&6 else b'')+raw+(bytes((padbyte,)) if len(raw)%2 else b'')+(b'' if dx is None else S(*dx)))
def et(text='HH',xy=(8,28),dx=None,options=0,rect=(4,4,48,40)):
 raw=pad(text.encode('utf-16le'));offdx=76+len(raw) if dx is not None else 0
 return er(84,I(0,0,96,64)+U(1)+F(1,1)+I(*xy)+U(len(text.encode('utf-16le'))//2,76,options)+I(*rect)+U(offdx)+raw+(b'' if dx is None else I(*dx)))
def write(name,ws,es=None,**kw):
 (P/('wmf-text-'+name+'.wmf')).write_bytes(wmfb(ws,**kw))
 if es is not None:(P/('wmf-text-'+name+'-control.emf')).write_bytes(emfb(es,**kw))
def bad(name,rs,**kw):(P/('unsupported-wmf-text-'+name+'.wmf')).write_bytes(wmfb(rs,**kw))
for name,raw,text in [('even',b'HH','HH'),('odd',b'HHH','HHH'),('cp1252',b'\x80\xe9','€é'),('empty',b'','')]:
 write('textout-'+name,[wt(raw,padbyte=0xa5)],[et(text)])
 write('ext-'+name,[wx(raw,padbyte=0xa5)],[et(text)])
write('ext-dx',[wx(b'HHH',dx=(28,28,28))],[et('HHH',dx=(28,28,28))])
write('ext-dx-negative',[wx(b'HHH',xy=(60,28),dx=(-20,-20,0))],[et('HHH',xy=(60,28),dx=(-20,-20,0))])
for name,opt in [('clip',4),('opaque',2),('clip-opaque',6)]:write('ext-'+name,[wx(b'HHH',options=opt,rect=(4,4,24,40))],[et('HHH',options=opt,rect=(4,4,24,40))])
write('ext-empty-opaque',[wx(b'',options=2,rect=(4,4,92,56))],[et('',options=2,rect=(4,4,92,56))])
for name,align in [('top',0),('bottom',8),('center',30),('right',26)]:write('align-'+name,[wx(b'HH',xy=(48,28),dx=(20,20))],[et('HH',xy=(48,28),dx=(20,20))],align=align)
for name,operation in [('textout',wt),('ext',wx)]:
 write(name+'-updatecp',[wr(0x214,S(28,8)),operation(b'H',xy=(90,50)),operation(b'H',xy=(90,50))],[er(27,I(8,28)),et('H',xy=(90,50)),et('H',xy=(90,50))],align=25)
write('ext-updatecp-dx',[wr(0x214,S(28,8)),wx(b'H',xy=(90,50),dx=(28,)),wx(b'H',xy=(90,50),dx=(28,))],[er(27,I(8,28)),et('H',xy=(90,50),dx=(28,)),et('H',xy=(90,50),dx=(28,))],align=25)
for name,options in [('cell',dict(height=18)),('width',dict(width=12)),('angle',dict(angle=450)),('orientation',dict(orientation=900)),('italic',dict(italic=1)),('underline',dict(underline=1)),('strike',dict(strike=1)),('bold',dict(weight=700)),('decorated',dict(italic=1,underline=1,strike=1))]:write('font-'+name,[wx(b'HH',xy=(32,40),dx=(20,20))],[et('HH',xy=(32,40),dx=(20,20))],**options)
write('background-opaque',[wt()],[et()],bk=2)
write('restore',[wr(0x1e),wr(0x416,S(40,24,4,4)),wr(0x209,U(255)),wx(b'HHH'),wr(0x127,S(-1)),wx(b'H',xy=(64,52))],[er(33),er(30,I(4,4,24,40)),er(24,U(255)),et('HHH'),er(34,I(-1)),et('H',xy=(64,52))])
write('translated',[wr(0x20d,S(8,4)),wx(b'HH',dx=(28,28))],[er(35,F(1,0,0,1,4,8)),et('HH',dx=(28,28))])
write('scaled',[wr(0x20c,S(128,192)),wx(b'HH',xy=(16,56),dx=(56,56))],[er(35,F(.5,0,0,.5,0,0)),et('HH',xy=(16,56),dx=(56,56))])
for charset,encoding,text in [(238,'cp1250','ŁH'),(204,'cp1251','ЯH'),(161,'cp1253','ΩH'),(162,'cp1254','ĞH'),(177,'cp1255','אH'),(178,'cp1256','عH'),(186,'cp1257','ĀH'),(163,'cp1258','đH'),(222,'cp874','กH')]:write('charset-'+str(charset),[wx(text.encode(encoding),dx=(28,28))],[et(text,dx=(28,28))],charset=charset)
for charset,encoding,text in [(128,'shift_jis','あH'),(129,'cp949','갂H'),(134,'gbk','你H'),(136,'big5','你H')]:
 raw=text.encode(encoding);write('dbcs-'+str(charset),[wx(raw,dx=(12,16,28))],[et(text,dx=(28,28))],charset=charset)
 for suffix,b in [('lead',raw[:1]),('trail',raw[:1]+b'\x20')]:bad('dbcs-'+str(charset)+'-'+suffix,[wx(b)],charset=charset)
# Fully framed invalid inner record payloads: no earlier valid pixels may leak.
for name,body in [('textout-short',H(2)+b'H\0'),('textout-count',H(32767)+b'H\0'+S(28,8)),('textout-trailing',H(2)+b'HH'+S(28,8)+S(0))]:bad(name,[wr(0x521,body)])
for name,body in [('ext-short',S(28,8,2)),('ext-negative-count',S(28,8,-1)+H(0)),('ext-missing-rectangle',S(28,8,2)+H(6)+b'HH'),('ext-short-dx',S(28,8,3)+H(0)+b'HHH\0'+S(20)),('ext-extra-dx',S(28,8,2)+H(0)+b'HH'+S(20,20,20)),('ext-glyph',S(28,8,2)+H(0x10)+b'HH'),('ext-option',S(28,8,2)+H(0x8000)+b'HH'),('ext-pdy',S(28,8,2)+H(0x2000)+b'HH'+S(20,0,20,0))]:bad(name,[wr(0xa32,body)])
bad('ansi-default-high',[wx(b'\x80')],charset=1)
bad('symbol-ascii',[wx(b'H')],charset=2)
bad('font-short',[wr(0x2fb,S(-18,0,0)),wr(0x12d,H(2)),wx()])
bad('textout-aggregate-budget',[wt(b' '*32767)]*9)
bad('ext-aggregate-budget',[wx(b' '*32767,dx=(0,)*32767)]*9)
# Same affine parent and logical source rectangle around independent WMF/EMF
# children: a second application of the child's map changes every ink origin.
def ep(t,b=b'',flags=0):return H(t,flags)+U(12+len(pad(b)),len(b))+pad(b)
def embedded(kind,child):
 rs=[ep(0x4001,U(0xdbc01002,1,96,96),1),ep(0x400a,U(0xffffffff,1)+F(0,0,96,64),0x8000),ep(0x4008,U(0xdbc01002,2,kind,len(child))+child,0x500),ep(0x401b,U(0xffffffff,2)+F(0,0,96,64)+U(3)+F(8,8,80,12,12,56)),ep(0x4002)]
 stream=b'EMF+'+b''.join(rs);records=[er(70,U(len(stream))+stream),er(14,U(0,0,20))]
 return U(1,88)+I(0,0,96,64)+I(0,0,2540,1693)+U(0x464d4520,0x10000,88+sum(map(len,records)),len(records)+1)+H(32,0)+U(0,0,0)+I(960,960,254,254)+b''.join(records)
childw=wmfb([wx(b'HHH',xy=(12,32),dx=(24,24,24))]);childe=emfb([et('HHH',xy=(12,32),dx=(24,24,24))])
(P/'wmf-text-embedded-affine.emf').write_bytes(embedded(2,childw))
(P/'wmf-text-embedded-affine-control.emf').write_bytes(embedded(3,childe))
