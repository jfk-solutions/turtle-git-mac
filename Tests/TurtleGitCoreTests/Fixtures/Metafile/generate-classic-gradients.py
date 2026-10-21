#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Original independent EMR118 wire fixtures. No renderer/test is executed.
MS-EMF 2.3.5.12, TRIVERTEX, GRADIENT_RECT/TRIANGLE; ignored Alpha/padding.
"""
import pathlib,struct
P=pathlib.Path(__file__).parent
U=lambda *v:struct.pack('<'+'I'*len(v),*v)
I=lambda *v:struct.pack('<'+'i'*len(v),*v)
H=lambda *v:struct.pack('<'+'H'*len(v),*v)
F=lambda *v:struct.pack('<'+'f'*len(v),*v)
def rec(t,b=b''):
 b+=b'\0'*(-len(b)%4);return U(t,len(b)+8)+b
def emit(name,records,w=64,h=64):
 rs=[*records,rec(14,U(0,0,20))]
 header=U(1,88)+I(0,0,w,h)+I(0,0,round(w*2540/96),round(h*2540/96))+U(0x464d4520,0x10000,88+sum(map(len,rs)),len(rs)+1)+H(32,0)+U(0,0,0)+I(960,960,254,254)
 (P/(name+'.emf')).write_bytes(header+b''.join(rs))
def vertex(x,y,r,g,b,a=0):return I(x,y)+H(r,g,b,a)
def gradient(v,meshes,mode=2,padding=True):
 body=I(-100,-100,100,100)+U(len(v),len(meshes),mode)+b''.join(v)+b''.join(U(*mesh) for mesh in meshes)
 if mode<2 and padding:body+=U(*([0xdeadbeef]*len(meshes)))
 return rec(118,body)
def bg():return [rec(37,U(0x80000008)),rec(37,U(0x80000000)),rec(43,I(0,0,64,64))]
R=(65280,0,0);G=(0,65280,0);B=(0,0,65280);Y=(65280,65280,0)
tri=[vertex(8,8,*R),vertex(56,8,*G,65535),vertex(8,56,*B,12345)]
rectangle=[vertex(8,8,*R),vertex(56,56,*B,65535)]
emit('classic-gradient-triangle',bg()+[gradient(tri,[(0,1,2)])])
emit('classic-gradient-triangle-reversed',bg()+[gradient(tri,[(0,2,1)])])
emit('classic-gradient-alpha-ignored',bg()+[gradient([vertex(8,8,*R,65535),vertex(56,8,*G),vertex(8,56,*B)],[(0,1,2)])])
emit('classic-gradient-triangle-shear',bg()+[rec(35,F(1,.25,.5,1,0,0)),gradient(tri,[(0,1,2)])])
square=[vertex(8,8,*R),vertex(56,8,*G),vertex(56,56,*B),vertex(8,56,*Y)]
emit('classic-gradient-shared-edge',bg()+[gradient(square,[(0,1,2),(0,2,3)])])
emit('classic-gradient-shared-edge-reversed',bg()+[gradient(square,[(2,1,0),(3,2,0)])])
overlap=[vertex(8,8,*R),vertex(56,8,*R),vertex(8,56,*R),vertex(16,16,*B),vertex(48,16,*B),vertex(16,48,*B)]
emit('classic-gradient-mesh-order',bg()+[gradient(overlap,[(0,1,2),(3,4,5)])])
emit('classic-gradient-degenerate',bg()+[gradient([vertex(8,8,*R),vertex(24,24,*G),vertex(48,48,*B)],[(0,1,2)])])
for mode,name in [(0,'horizontal'),(1,'vertical')]:
 emit('classic-gradient-rectangle-'+name,bg()+[gradient(rectangle,[(0,1)],mode)])
 emit('classic-gradient-rectangle-'+name+'-compact',bg()+[gradient(rectangle,[(0,1)],mode,False)])
emit('classic-gradient-rectangle-rotated',bg()+[rec(35,F(0,1,-1,0,64,0)),gradient(rectangle,[(0,1)],0)])
emit('classic-gradient-rectangle-sheared',bg()+[rec(35,F(1,0,.5,1,0,0)),gradient(rectangle,[(0,1)],0)])
emit('classic-gradient-rectangle-mirrored',bg()+[rec(35,F(-1,0,0,1,64,0)),gradient(rectangle,[(0,1)],1)])
emit('classic-gradient-clip-restored',bg()+[rec(33),rec(30,I(16,16,40,40)),rec(35,F(1,0,.5,1,0,0)),gradient(rectangle,[(0,1)],0),rec(34,I(-1)),gradient([vertex(44,44,*G),vertex(60,60,*G)],[(0,1)],1)])
emit('classic-gradient-outside',bg()+[gradient([vertex(-32,-32,*R),vertex(96,-32,*G),vertex(-32,96,*B)],[(0,1,2)])])
emit('classic-gradient-empty',bg()+[gradient([],[])])
# Declared valid prefix must never become a plausible partial image on errors.
prefix=bg()+[gradient(tri,[(0,1,2)])]
invalid={
 'index-after-paint':gradient(tri,[(0,1,3)]),
 'triangle-truncated':rec(118,I(0,0,64,64)+U(3,1,2)+b''.join(tri)+U(0,1)),
 'triangle-extra':rec(118,I(0,0,64,64)+U(3,1,2)+b''.join(tri)+U(0,1,2,0)),
 'rectangle-partial-padding':rec(118,I(0,0,64,64)+U(2,2,0)+b''.join(rectangle)+U(0,1,0,1,123)),
 'rectangle-extra-padding':rec(118,I(0,0,64,64)+U(2,1,0)+b''.join(rectangle)+U(0,1,123,456)),
 'mode':gradient(tri,[(0,1,2)],3),
 'header':rec(118,I(0,0,64,64)+U(3,1)),
 'vertex-count':rec(118,I(0,0,64,64)+U(0xffffffff,1,2)),
 'mesh-count':rec(118,I(0,0,64,64)+U(3,0xffffffff,2)),
 'mesh-work-budget':gradient([vertex(0,0,*R),vertex(64,0,*G),vertex(0,64,*B)],[(0,1,2)]*16385),
 'transform-range':None,
}
for name,value in invalid.items():
 records=prefix+([rec(35,F(1e30,0,0,1e30,0,0)),gradient(tri,[(0,1,2)])] if value is None else [value])
 emit('unsupported-gradient-classic-'+name,records)
print('Classic GradientFill corpus: 18 valid, 11 refusal fixtures')
