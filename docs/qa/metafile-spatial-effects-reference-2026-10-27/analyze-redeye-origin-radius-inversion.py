#!/usr/bin/env python3
"""Bounded inverse-geometry diagnostic, not a detector or shipping predictor.

Every candidate center/radius is reported, not selected for application output.
The two symmetric offcenter square cases delimit whether any simple diagonal
origin/radius perturbation can close the existing computed-histogram model.
Observed buffers score hypotheses only and never supply predicted pixel values.
"""
import json,math,importlib.util
from pathlib import Path
from collections import defaultdict
sp=importlib.util.spec_from_file_location('r',Path('docs/qa/metafile-spatial-effects-reference-2026-10-27/analyze-redeye-rgb-dispersion.py'));m=importlib.util.module_from_spec(sp);sp.loader.exec_module(m)
p=Path('build/qa/metafile-redeye-followup-native-windows-2026-10-27');j=json.load(open(p/'replay.json'));out=[]
for name in ['square-8-at4','square-8-at20']:
 a=(p/next(c for c in j['cases']if c['atlas']==name)['rgba']).read_bytes();s=(p/('atlas-'+name+'.rgba')).read_bytes();source=[tuple(s[i:i+4])for i in range(0,len(s),4)];rows=[]
 for step in range(289):
  cx=cy=14.5+(step%17)/8;radius=13.5+(step//17)/4;bins=defaultdict(list);coords={}
  for y in range(32):
   for x in range(32):
    rho=math.hypot(x-cx,y-cy)/radius
    if rho>=1:continue
    b=int((math.degrees(math.atan2(y-cy,x-cx))%360)//6);coords[x,y]=(rho,b);bins[b].append(source[y*32+x])
  reds={b:m.reduction(v,(240,20,10,255))for b,v in bins.items()};errors=[];bad=0;ma=0
  for y in range(32):
   for x in range(32):
    pix=source[y*32+x];pred=pix
    if pix[0]==240 and (x,y)in coords:
     rho,b=coords[x,y];q=1-rho;part=reds[b];h=part['linearExcess'];S=max(part['strength'],220*(h+(1-h)*q*q/4));pred=m.corrected(pix,S)
    i=4*(y*32+x);d=[abs(v-w)for v,w in zip(pred,a[i:i+4])];bad+=max(d)>1;ma=max(ma,max(d));errors.extend(d)
  rows.append(dict(center=cx,radius=radius,bad=bad,max=ma,sum=sum(errors)))
 print(name,sorted(rows,key=lambda x:x['sum'])[:8]);out.append(dict(name=name,qualification='Bounded per-observation inverse constraints only; no best coordinate is accepted as a detector or reused by production.',rows=rows))
Path('build/qa/redeye-origin-radius-inversion-2026-10-27.json').write_text(json.dumps(out,indent=2)+'\n')
