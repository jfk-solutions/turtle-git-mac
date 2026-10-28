#!/usr/bin/env python3
"""Decode independent native coefficient observations; never executes renderer."""
from pathlib import Path
import json,sys,math,hashlib
ROOT=Path(sys.argv[1]); rows=[]
def clip(poly,a,b,limit):
 out=[]
 for p,q in zip(poly,poly[1:]+poly[:1]):
  fp=a*p[0]+b*p[1]-limit;fq=a*q[0]+b*q[1]-limit
  pin=fp<=1e-12;qin=fq<=1e-12
  if pin:out.append(p)
  if pin!=qin:
   t=fp/(fp-fq);out.append((p[0]+t*(q[0]-p[0]),p[1]+t*(q[1]-p[1])))
 return out
for mode in ['generate','direct-v1','replay','replay-v1']:
 manifest=json.loads((ROOT/(mode+'.json')).read_text())
 for case in manifest['cases']:
  if 'error'in case:rows.append(dict(mode=mode,name=case['name'],error=case['error']));continue
  views=[('direct',case.get('direct')),('created',case.get('created'))]if mode in ['generate','direct-v1']else[('intrinsic',case.get('intrinsic')),('final',case)]
  for view,image in views:
   if not image or 'rgba'not in image:continue
   data=(ROOT/image['rgba']).read_bytes();w=image['width'];h=image['height'];samples=[]
   if (w,h)!=(32,266):raise ValueError('Unexpected diagnostic dimensions')
   if len(data)!=w*h*4:raise ValueError('Unexpected RGBA extent')
   grayErrors=alphaErrors=0
   for amp in range(256):
    y=10+amp
    for x in range(w):
     pixel=data[(y*w+x)*4:(y*w+x)*4+4];grayErrors+=pixel[0]!=pixel[1]or pixel[0]!=pixel[2];alphaErrors+=pixel[3]!=255
   for x in range(32):
    vals=[data[((10+a)*w+x)*4]for a in range(256)]
    if case['secondX']<0:
     lower=max([(v-.5)/a for a,v in enumerate(vals)if a]+[0]);upper=min([(v+.5)/a for a,v in enumerate(vals)if a]+[2]);samples.append(dict(x=x,minimum=lower,maximum=upper,feasible=lower<=upper+1e-12,zeroOutput=vals[0]))
    else:
     polygon=[(0,0),(2,0),(2,2),(0,2)]
     for a,v in enumerate(vals):
      polygon=clip(polygon,a,255-a,v+.5)
      if not polygon:break
      polygon=clip(polygon,-a,a-255,.5-v)
      if not polygon:break
     samples.append(dict(x=x,feasible=bool(polygon),vertices=polygon))
   rows.append(dict(mode=mode,view=view,name=case['name'],file=image['rgba'],SHA256=hashlib.sha256(data).hexdigest(),nonGraySamples=grayErrors,nonOpaqueSamples=alphaErrors,columns=samples))
report=dict(scope='Native direct/created/Bitmap diagnostic only, not application verification',roundingIntervals='Closed ±0.5 output intervals; feasible does not establish exact tie convention',observations=rows)
out=Path(sys.argv[2])if len(sys.argv)>2 else ROOT/'coefficient-analysis.json';out.write_text(json.dumps(report,indent=2)+'\n')
for r in rows:
 if 'columns'in r:print(r['mode'],r['view'],r['name'],'nonlinearcolumns',[c['x']for c in r['columns']if not c['feasible']],'gray',r['nonGraySamples'],'alpha',r['nonOpaqueSamples'])
