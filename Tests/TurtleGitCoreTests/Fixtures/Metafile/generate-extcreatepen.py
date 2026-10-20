#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Original deterministic EMR_EXTCREATEPEN fixtures (MS-EMF LogPenEx).
No renderer/test process is invoked. Offsets include the 8-byte record header.
"""
import pathlib, struct
P=pathlib.Path(__file__).parent
U=lambda *v:struct.pack('<'+'I'*len(v),*v)
I=lambda *v:struct.pack('<'+'i'*len(v),*v)
H=lambda *v:struct.pack('<'+'H'*len(v),*v)
F=lambda *v:struct.pack('<'+'f'*len(v),*v)
def rec(t,b=b''):
 b+=b'\0'*(-len(b)%4);return U(t,len(b)+8)+b
def write(n,rs):
 rs=[*rs,rec(14,U(0,0,20))]
 header=U(1,88)+I(0,0,64,64)+I(0,0,1693,1693)+U(0x464d4520,0x10000,88+sum(map(len,rs)),len(rs)+1)+H(32,0)+U(0,0,0)+I(960,960,254,254)
 (P/(n+'.emf')).write_bytes(header+b''.join(rs))
def select(n):return rec(37,U(n))
def pen(style=0x12200,width=4,brush=0,color=255,hatch=0,entries=(),dib=None,gap=0):
 data=U(*entries);off=52+len(data)+gap
 bmi,bits=dib if dib else (b'',b'')
 return rec(95,U(1,off if dib else 0,len(bmi),off+len(bmi) if dib else 0,len(bits),style,width,brush,color,hatch,len(entries))+data+b'\0'*gap+bmi+bits)
def line(y=16,x=8,end=56):return [rec(27,I(x,y)),rec(54,I(end,y))]
def setup(p):return [select(0x80000005),p,select(1)] # hollow fill
for name,style,width,entries in [('custom',0x12207,4,(8,4)),('mixed-zero',0x12207,4,(8,0)),('odd',0x12207,4,(8,4,2)),('cosmetic',7,1,(8,4)),('alternate',8,1,()),('dash',0x12201,4,()),('dot',0x12202,4,()),('dashdot',0x12203,4,()),('dashdotdot',0x12204,4,())]:
 write('classic-extpen-'+name,setup(pen(style,width,entries=entries))+[rec(18,U(2)),rec(25,U(0x00ff00))]+line())
write('classic-extpen-alternate-vertical',setup(pen(8,1))+[rec(27,I(16,8)),rec(54,I(16,56))])
write('classic-extpen-alternate-diagonal',setup(pen(8,1))+[rec(27,I(8,8)),rec(54,I(56,56))])
write('classic-extpen-alternate-polyline',setup(pen(8,1))+[rec(4,I(0,0,64,64)+U(3)+I(8,16,13,16,13,40))])
write('classic-extpen-alternate-transform-clip',setup(pen(8,1))+[rec(30,I(16,0,40,64)),rec(35,F(2,0,0,4,0,0)),*line(8,4,28)])
write('classic-extpen-null-brush',setup(pen(0x12200,8,1))+line(32))
write('classic-extpen-cosmetic-known-cap-join',setup(pen(0x2207,1,entries=(8,4)))+[rec(18,U(2)),rec(25,U(0x00ff00))]+line())
for name,cap in [('round',0),('flat',0x200)]:
 write('classic-extpen-zero-on-'+name,setup(pen(0x12007|cap,4,entries=(0,4)))+line(32))
for name,cap in [('round',0),('square',0x100),('flat',0x200)]:
 write('classic-extpen-cap-'+name,setup(pen(0x12000|cap,8))+line(32,16,48))
 write('classic-extpen-dashcap-'+name,setup(pen(0x12007|cap,8,entries=(16,16)))+line(32))
for name,join in [('round',0),('bevel',0x1000),('miter',0x2000)]:
 pts=[16,48,32,16,48,48]
 write('classic-extpen-join-'+name,setup(pen(0x10200|join,8))+[rec(4,I(0,0,64,64)+U(3)+I(*pts))])
for name,limit in [('float-low',F(1)),('float-high',F(10)),('uint-high',U(10))]:
 write('classic-extpen-miter-'+name,setup(pen(0x12200,8))+[rec(58,limit),rec(4,I(0,0,64,64)+U(3)+I(16,48,32,16,48,48))])
write('classic-extpen-miter-restored',setup(pen(0x12200,8))+[rec(58,U(10)),rec(33),rec(58,F(1)),rec(34,I(-1)),rec(4,I(0,0,64,64)+U(3)+I(16,48,32,16,48,48))])
write('classic-extpen-width-zero-scale',setup(pen(0x12200,0))+[rec(35,F(2,0,0,4,0,0)),*line(8,4,28)])
for kind,record in [('rectangle',rec(43,I(12,12,52,52))),('ellipse',rec(42,I(12,12,52,52))),('roundrect',rec(44,I(12,12,52,52)+I(12,12)))]:
 write('classic-extpen-inside-'+kind,setup(pen(0x12206,8))+[record])
write('classic-extpen-inside-open',setup(pen(0x12206,8))+line(32,16,48))
for h in range(6):write('classic-extpen-hatch-'+str(h),setup(pen(0x12200,12,2,255,h))+line(32))
bmi=U(40)+I(2,-2)+H(1,32)+U(0,16,0,0,0,0)
bits=bytes([0,0,255,0,255,0,0,0,255,0,0,0,0,0,255,0])
write('classic-extpen-dib',setup(pen(0x12200,12,6,0,0,dib=(bmi,bits),gap=12))+line(32))
write('classic-extpen-state',[*setup(pen()),rec(33),rec(30,I(0,0,32,64)),rec(35,F(2,0,0,1,0,0)),*line(16,4,28),rec(34,I(-1)),*line(48)])
write('classic-extpen-rop2',[*setup(pen(color=0xffffff)),rec(20,U(7)),*line(32)]) # XOR white DC -> black
write('classic-extpen-cosmetic-scale',[*setup(pen(7,1,entries=(8,4))),rec(35,F(2,0,0,4,0,0)),*line(8,4,28)])
# Every refusal contains a valid earlier mark; a partial image is never success.
prefix=[select(0x80000007),*line(8)] # stock pen: no duplicate handle masks malformed records
bad={
 'miter-nan':rec(58,F(float('nan'))), 'miter-infinite':rec(58,F(float('inf'))), 'miter-budget':rec(58,U(10000000)),
 'short':rec(95,b'\0'*40), 'count':pen(entries=(8,4))[:48]+U(17)+U(8,4),
 'zero-dash':pen(0x12207,entries=(0,0)), 'empty-user':pen(0x12207),
 'unexpected-array':pen(entries=(8,4)),
 'cosmetic-width':pen(0,4), 'cosmetic-brush':pen(0,1,2),
 'geometric-alternate':pen(0x12208), 'cosmetic-inside':pen(6,1),
 'style':pen(0x12209), 'reserved-flags':pen(0x80012200),
 'hatch':pen(brush=2,hatch=6), 'ddb':pen(brush=3),
 'dib-offset':rec(95,U(1,12,40,52,16,0x12200,4,6,0,0,0)+bmi+bits),
 'dib-overrun':rec(95,U(1,52,40,92,100,0x12200,4,6,0,0,0)+bmi+bits),
 'dib-overlap':rec(95,U(1,52,40,56,16,0x12200,4,6,0,0,0)+bmi+bits),
 'dib-missing':pen(brush=6), 'truncated-array':rec(95,U(1,0,0,0,0,0x12207,4,0,255,0,3)+U(8,4))}
for name,value in bad.items():write('unsupported-extpen-'+name,prefix+[value,select(1),*line(48)])
