#!/usr/bin/env python3
"""Original mathematical model for captured Windows spatial effects.

No renderer execution. Small-radius leading-row behavior is measured, and the
Q8 product profile is supported by independent full-byte source observations.
Remaining one-byte edge precision and the large-radius pyramid branch remain
explicitly qualified rather than guessed.
"""
import math


def normalize(rgba):
    result=bytearray(len(rgba))
    for i in range(0,len(rgba),4):
        a=rgba[i+3];result[i+3]=a
        if a:
            reciprocal=(255<<16)//a
            for c in range(3):result[i+c]=(((rgba[i+c]*a+127)//255)*reciprocal)>>16
    return bytes(result)


def weights(radius):
    if not math.isfinite(radius) or not 0<=radius<=255:raise ValueError('radius')
    if radius==0:return [1.]
    support=math.ceil(radius)
    values=[math.exp(-1.96*(offset/radius)**2) for offset in range(-support,support+1)]
    total=sum(values)
    return [v/total for v in values]


def byte(value):return max(0,min(255,math.floor(value+.5)))


def sample(position,limit,edge):
    if 0<=position<limit:return position
    if edge=='zero':return None
    if edge=='clamp':return max(0,min(limit-1,position))
    if edge!='mirror':raise ValueError('edge')
    if limit==1:return 0
    period=2*(limit-1);position%=period
    return position if position<limit else period-position


def blur(rgba,width,height,radius,expandEdge=False,*,edge=None,vertical=None):
    """Return (RGBA,width,height,originX,originY); input remains unchanged.

    Optional edge and vertical override exist only for transparent hypothesis
    comparisons. Defaults refuse the unresolved large-kernel dispatch profile.
    """
    if width<=0 or height<=0 or len(rgba)!=width*height*4:raise ValueError('RGBA dimensions')
    kernel=weights(radius);half=len(kernel)//2
    if radius==0:return bytes(rgba),width,height,0,0
    pad=math.ceil(radius) if expandEdge else 0
    outw,outh=width+2*pad,height+2*pad
    if edge is None:edge='zero' if expandEdge else 'mirror'
    if vertical is None:
        if radius>=min(width,height):raise NotImplementedError('large-radius dispatch profile unresolved')
        vertical=math.ceil(outh/outw)
    rows=outh if vertical=='all' else int(vertical)
    horizontal=bytearray(outw*outh*4)
    for y in range(height):
        for x in range(outw):
            value=[0.]*4
            for tap,weight in enumerate(kernel):
                sx=sample(x-pad+tap-half,width,edge)
                if sx is None:continue
                for c in range(4):value[c]+=math.floor(rgba[(y*width+sx)*4+c]*weight*256+.5)/256
            horizontal[((y+pad)*outw+x)*4:((y+pad)*outw+x)*4+4]=bytes(map(byte,value))
    result=bytearray(horizontal)
    for y in range(rows):
        for x in range(outw):
            value=[0.]*4
            for tap,weight in enumerate(kernel):
                sy=sample(y-pad+tap-half,height,edge)
                if sy is None:continue
                for c in range(4):value[c]+=math.floor(horizontal[((sy+pad)*outw+x)*4+c]*weight*256+.5)/256
            result[(y*outw+x)*4:(y*outw+x)*4+4]=bytes(map(byte,value))
    return bytes(result),outw,outh,-pad,-pad


def unsharp(rgba,blurred,amount):
    if len(rgba)!=len(blurred) or not 0<=amount<=100:raise ValueError('sharpen input')
    gain=math.floor(64*amount/(250-2*amount)+.5)
    output=bytearray(len(rgba))
    for i in range(0,len(rgba),4):
        values=[byte(rgba[i+c]+(rgba[i+c]-blurred[i+c])*gain/64)for c in range(4)]
        values[3]=max(values);output[i:i+4]=bytes(values)
    return bytes(output)
