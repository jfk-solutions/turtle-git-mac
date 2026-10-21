#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Original device-ROI/checkpoint regression scenes; never executes a renderer.

MS-EMF records deliberately alternate Boolean paints, ordinary vector nodes and
saved pattern/clip state. Oracles are literal colors and integer device positions.
"""
import pathlib
import struct
P = pathlib.Path(__file__).parent
U = lambda *v: struct.pack('<' + 'I' * len(v), *v)
I = lambda *v: struct.pack('<' + 'i' * len(v), *v)
H = lambda *v: struct.pack('<' + 'H' * len(v), *v)
F = lambda *v: struct.pack('<' + 'f' * len(v), *v)
def rec(t, b=b''):
    b += b'\0' * (-len(b) % 4)
    return U(t, len(b)+8)+b
def emf(rs):
    rs = [*rs, rec(14, U(0,0,20))]
    return (U(1,88)+I(0,0,64,64)+I(0,0,1693,1693)+U(0x464d4520,0x10000,88+sum(map(len,rs)),len(rs)+1)+H(32,0)+U(0,0,0)+I(960,960,254,254)+b''.join(rs))
def write(name, rs): (P/(name+'.emf')).write_bytes(emf(rs))
def brush(n, gray): return rec(39,U(n,0,gray*0x010101,0))
def select(n): return rec(37,U(n))
def rect(x,y,w,h): return rec(43,I(x,y,x+w,y+h))
def base(): return [select(0x80000008),brush(1,170),select(1),rect(0,0,64,64)]
def dib(values, w, h):
    bits=b''.join(bytes([v,v,v,0]) for v in values)
    return U(40)+I(w,-h)+H(1,32)+U(0,len(bits),0,0,0,0),bits
def blt(rop,x,y,w,h, *, values=(204,), size=(1,1), crop=(0,0,1,1), transform=(1,0,0,1,0,0)):
    bmi,bits=dib(values,*size)
    sx,sy,sw,sh=crop
    return rec(77,I(x,y,x+w,y+h)+I(x,y,w,h)+U(rop<<16)+I(sx,sy)+F(*transform)+U(0,0,108,len(bmi),108+len(bmi),len(bits))+I(sw,sh)+bmi+bits)
# Both off-diagonal destination terms are nonzero: a two-corner ROI is wrong.
# Source crop chooses middle gray bands, mirrored in source coordinates.
write('classic-roi-affine-crop',base()+[rec(35,F(1,.5,-.5,1,28,8)),blt(0xcc,0,0,16,16,values=(0,64,192,255),size=(4,1),crop=(1,0,2,1),transform=(-1,0,0,1,4,0))])
# Checkpoint->vector->checkpoint, then a full-canvas Boolean fill->small patch.
# Each output must include the immediately preceding scene, not an older snapshot.
write('classic-roi-checkpoint-interleave',base()+[
    blt(0x66,8,8,16,16),brush(2,32),select(2),rect(32,8,16,16),
    blt(0x66,32,8,16,16),blt(0x55,0,32,64,32),blt(0x66,48,40,8,8),
    blt(0xaa,0,0,64,64)])
# Retained defs must survive multiple serialized snapshots and SaveDC/RestoreDC.
bmi,bits=dib((0,255,255,0),2,2)
pattern=rec(94,U(3,0,32,len(bmi),32+len(bmi),len(bits))+bmi+bits)
write('classic-roi-saved-pattern',base()+[pattern,select(3),rec(13,I(1,0)),rec(33),
    rec(30,I(8,8,24,24)),blt(0xf0,0,0,32,32),
    brush(4,51),select(4),rect(12,12,8,8),blt(0x66,12,12,8,8),
    rec(34,I(-1)),blt(0xf0,40,40,8,8),blt(0xf0,8,40,8,8)])
# An invisible record must not erase earlier nodes or bypass payload validation.
write('classic-roi-offcanvas',base()+[blt(0x66,-80,-80,8,8),blt(0x66,60,60,16,16)])
bad=bytearray(blt(0x66,-80,-80,8,8));struct.pack_into('<I',bad,84,0x7fffffff)
write('unsupported-roi-offcanvas-payload',[bytes(bad)])
# NOP preserves the explicitly painted region and the initial opaque white DC.
write('classic-roi-alpha-nop',[select(0x80000008),brush(1,64),select(1),rect(8,8,16,16),blt(0xaa,0,0,64,64)])
# Generic noncopy ROP2 pen forces the conservative full-viewport path.
write('classic-roi-pen-fallback',base()+[rec(38,U(2,0)+I(4,0)+U(0xcccccc)),select(2),rec(20,U(7)),rec(27,I(8,32)),rec(54,I(56,32)),blt(0x66,8,8,8,8)])
# Asymmetric device Y and source crop; a vertically reversed ROI is observable.
write('classic-roi-asymmetric-y',base()+[blt(0xcc,40,44,16,12,values=(0,64,192,255),size=(1,4),crop=(0,1,1,2)),blt(0x66,4,8,8,4)])
