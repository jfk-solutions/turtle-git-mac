#!/usr/bin/env python3
"""Compare mathematical source masks and the existing scanline model to native bytes.
No TurtleGit executable, module or output is consumed.
"""
import json,math,pathlib,struct,os
PROFILE=os.environ.get("INTERPOLATION_REFERENCE_PROFILE","down")
ROOT=pathlib.Path(__file__).resolve().parent
P=ROOT/'windows-capture/output'
def f32(x):return struct.unpack('<f',struct.pack('<f',x))[0]
def down(x):
 if PROFILE in ["double","direct"]:return x
 r=f32(x)
 if PROFILE=="nearest":return r
 if r>x:
  bits=struct.unpack('<I',struct.pack('<f',r))[0]
  r=struct.unpack('<f',struct.pack('<I',bits+1 if r<0 else bits-1))[0]
 return r
def stage(value,index):
 if PROFILE.startswith('mixed-'):
  if PROFILE[6+index]=='N':return f32(value)
  if PROFILE[6+index]=='Z':
   r=f32(value)
   if abs(r)>abs(value):
    bits=struct.unpack('<I',struct.pack('<f',r))[0];r=struct.unpack('<f',struct.pack('<I',bits-1))[0]
   return r
  return down(value)
 return down(value)
colors=[bytes([255,0,0,255]),bytes([0,255,0,255]),bytes([0,0,255,255]),bytes([255,255,0,255])]
result=[]
for case in json.loads((P/'interpolation-observations.json').read_text())['cases']:
 if case['mode']!=5:continue
 colors=[bytes([255,0,0,255]),bytes([0,255,0,128]),bytes([0,0,255,64]),bytes(4)] if case['alpha'] else [bytes([255,0,0,255]),bytes([0,255,0,255]),bytes([0,0,255,255]),bytes([255,255,0,255])]
 m=[1,0,0,1,0,0]
 for r in json.loads((P/(case['name']+'-records.json')).read_text()):
  b=bytes.fromhex(r['bodyHex'])
  if r['type']==0x402a:m=struct.unpack('<6f',b)
  if r['type']==0x401b:
   sx,sy,sw,sh=struct.unpack_from('<4f',b,8)
   coords=struct.unpack_from('<6h' if r['flags']&0x4000 else '<6f',b,28)
   pts=[(m[0]*x+m[2]*y+m[4],m[1]*x+m[3]*y+m[5]) for x,y in zip(coords[::2],coords[1::2])]
 (ax,ay),(bx,by),(cx,cy)=pts;a=(bx-ax)/sw;b=(by-ay)/sw;c=(cx-ax)/sh;d=(cy-ay)/sh;tx=ax-a*sx-c*sy;ty=ay-b*sx-d*sy;det=a*d-b*c
 corners=[pts[0],pts[1],(bx+cx-ax,by+cy-ay),pts[2]]
 left=max(0,min(32,math.ceil(min(x for x,y in corners))));right=max(0,min(32,math.ceil(max(x for x,y in corners))))
 top=max(0,min(24,math.ceil(min(y for x,y in corners))));bottom=max(0,min(24,math.ceil(max(y for x,y in corners))))
 phase=.5 if case['pixelOffset']==4 else 0
 axis=b==0 and c==0;stepu=float(f32(1/f32(a))) if axis else stage(d/det,1);stepv=0 if axis else stage(-b/det,1);vertical=stage(sh*stage(1/(d*sh),1),1) if axis else 0
 native=(P/(case['name']+'-natural.rgba')).read_bytes();model=bytearray(32*24*4);trace=[]
 for y in range(top,bottom):
  intersections=[]
  for i in range(4):
   px,py=corners[i];qx,qy=corners[(i+1)%4];scan=y+phase
   if py==qy or scan<min(py,qy) or scan>=max(py,qy):continue
   intersections.append(px+(qx-px)*(scan-py)/(qy-py))
  if not intersections:continue
  start=max(left,min(right,math.ceil(min(intersections)-phase)));end=max(left,min(right,math.ceil(max(intersections)-phase)))
  if end<=start:continue
  if axis:u=stage(float(f32(sx))+stage((start+phase-ax)*stepu,0),0);v=stage(float(f32(sy))+stage((y+phase-ay)*vertical,0),0)
  else:u=stage((d*(start+phase-tx)-c*(y+phase-ty))/det,0);v=stage((-b*(start+phase-tx)+a*(y+phase-ty))/det,0)
  for x in range(start,end):
   if PROFILE=="direct":
    u=(d*(x+phase-tx)-c*(y+phase-ty))/det;v=(-b*(x+phase-tx)+a*(y+phase-ty))/det
   if PROFILE.startswith("matrix-float"):
    ia,ib,ic,id,itx,ity=[f32(z) for z in [d/det,-b/det,-c/det,a/det,(c*ty-d*tx)/det,(b*tx-a*ty)/det]]
    def transform(k,l,t):
     px=f32(k*f32(x+phase));py=f32(l*f32(y+phase))
     if PROFILE=="matrix-float-translate-first":return f32(f32(px+t)+py)
     return f32(f32(px+py)+t)
    u=transform(ia,ic,itx);v=transform(ib,id,ity)
   if PROFILE.endswith('-bias32'):
    ix=math.floor(f32(f32(u-phase)+.5));iy=math.floor(f32(f32(v-phase)+.5))
   else:ix=math.floor(u-phase+.5);iy=math.floor(v-phase+.5)
   if case['name']=='opaque-i5-p4-affine' and y in [7,8,11,12] and 6<=x<=13:
    trace.append({'xy':[x,y],'rowStart':start,'step':[stepu,stepv],'source':[u,v],'sourceMinusPhase':[u-phase,v-phase],'index':[ix,iy],'native':list(native[(y*32+x)*4:(y*32+x+1)*4])})
   if 0<=ix<2 and 0<=iy<2:model[(y*32+x)*4:(y*32+x+1)*4]=colors[iy*2+ix]
   u=stage(u+stepu,2);v=stage(v+stepv,2)
 bad=[{'xy':[i//4%32,i//4//32],'native':list(native[i:i+4]),'scanline':list(model[i:i+4])} for i in range(0,len(native),4) if native[i:i+4]!=model[i:i+4]]
 result.append({'name':case['name'],'mismatches':len(bad),'differences':bad,'crossings':trace})
print(json.dumps({'profile':PROFILE,'total_mismatches':sum(c['mismatches'] for c in result),'failed_cases':[{'name':c['name'],'mismatches':c['mismatches']} for c in result if c['mismatches']]}))
(ROOT/('nearest-scanline-'+PROFILE+'-analysis.json')).write_text(json.dumps({'profile':PROFILE,'stage_codes':'N=nearest Float32; D=down Float32; Z=toward-zero Float32; mixed codes are row-start inverse, inverse increments, incremental additions; bias32 rounds source-phase subtraction and nearest0.5 addition in Float32','model':'device affine scanline; phase-offset scan y, ceil(minx-phase)..ceil(maxx-phase), original ceil bbox; source sample minus phase; nearest floor(sample+.5)','cases':result},indent=2)+'\n')
