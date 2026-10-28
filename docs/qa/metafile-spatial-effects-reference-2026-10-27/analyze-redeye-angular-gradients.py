#!/usr/bin/env python3
"""Full-buffer angular/geometry hypotheses for independent gradient sources.

Candidates are fixed source-statistic recipes, never selected by observed pixel
values or case names. Native output scores each complete buffer only. Reported
best scores are diagnostic rankings and are not a production detector.
"""
import argparse,hashlib,json,math
from pathlib import Path
import numpy as np

def digest(b):return hashlib.sha256(b).hexdigest()
def weights(rgb,name):
 r,g,b=rgb[...,0],rgb[...,1],rgb[...,2]
 if name=='red-excess':return np.maximum(0,r-(g+b)/2)
 if name=='red-maximum':return np.maximum(0,r-np.maximum(g,b))
 if name=='red-green':return np.maximum(0,r-g)
 if name=='red-blue':return np.maximum(0,r-b)
 if name=='red-ratio-green':return np.divide(r,g,out=np.zeros_like(r),where=g>0)
 if name=='red-ratio-blue':return np.divide(r,b,out=np.zeros_like(r),where=b>0)
 if name=='red-ratio-greenblue':return np.divide(r,g+b,out=np.zeros_like(r),where=g+b>0)
 if name=='excess-ratio-green':return np.divide(np.maximum(0,r-(g+b)/2),g,out=np.zeros_like(r),where=g>0)
 if name=='excess-ratio-blue':return np.divide(np.maximum(0,r-(g+b)/2),b,out=np.zeros_like(r),where=b>0)
 if name=='excess-ratio-greenblue':return np.divide(np.maximum(0,r-(g+b)/2),g+b,out=np.zeros_like(r),where=g+b>0)
 if name=='red-green-ratio-green':return np.divide(np.maximum(0,r-g),g,out=np.zeros_like(r),where=g>0)
 if name=='red-green-ratio-greenblue':return np.divide(np.maximum(0,r-g),g+b,out=np.zeros_like(r),where=g+b>0)
 if name=='red-maximum-ratio-maximum':
  m=np.maximum(g,b);return np.divide(np.maximum(0,r-m),m,out=np.zeros_like(r),where=m>0)
 if name=='red-ratio-maximum':
  m=np.maximum(g,b);return np.divide(r,m,out=np.zeros_like(r),where=m>0)
 if name=='red-ratio-rgb':return np.divide(r,r+g+b,out=np.zeros_like(r),where=r+g+b>0)
 raise ValueError(name)

def predict(s,cx,cy,rx,ry,formula,radial):
 h,w,_=s.shape;Y,X=np.mgrid[:h,:w];rho=np.hypot((X-cx)/rx,(Y-cy)/ry);inside=rho<1
 bins=(np.degrees(np.arctan2(Y-cy,X-cx))%360//6).astype(int)
 r,g,b=s[...,0],s[...,1],s[...,2];z=np.maximum(0,r-(g+b)/2);M=np.maximum(0,r-np.maximum(g,b));mu=np.zeros((60,4))
 for k in range(60):
  sample=inside&(bins==k)
  if sample.any():mu[k]=[r[sample].mean(),g[sample].mean(),b[sample].mean(),z[sample].mean()]
 mr,mg,mb,mz=[mu[bins,k]for k in range(4)]
 safe=lambda a,d:np.divide(a,d,out=np.zeros_like(a),where=d!=0)
 hz=safe(z-mz,z);dg,db=mg-g,mb-b
 if formula=='mixture-mean':
  extra=safe((1-hz)*abs(dg)*dg*db,mg*(abs(dg)*mb+abs(db)*mg));floor=np.where(hz>0,M*np.maximum(0,hz+extra),0)
 elif formula=='z-excess':floor=M*np.maximum(0,hz)
 elif formula=='red-green-excess':floor=M*np.maximum(0,safe((r-g)-(mr-mg),r-g))
 elif formula=='red-blue-excess':floor=M*np.maximum(0,safe((r-b)-(mr-mb),r-b))
 elif formula=='red-ratio-green':floor=M*np.maximum(0,safe(r*mg-g*mr,(r-g)*mg))
 elif formula=='red-ratio-blue':floor=M*np.maximum(0,safe(r*mb-b*mr,(r-b)*mb))
 elif formula=='red-ratio-greenblue':floor=M*np.maximum(0,safe(r*(mg+mb)-(g+b)*mr,(2*r-g-b)*(mg+mb)/2))
 else:raise ValueError(formula)
 if radial=='z':hh=hz
 elif radial=='red-green':hh=safe((r-g)-(mr-mg),r-g)
 elif radial=='red-blue':hh=safe((r-b)-(mr-mb),r-b)
 elif radial=='ratio-green':hh=safe(r*mg-g*mr,(r-g)*mg)
 elif radial=='ratio-blue':hh=safe(r*mb-b*mr,(r-b)*mb)
 else:raise ValueError(radial)
 strength=np.maximum(0,np.maximum(floor,M*(hh+(1-hh)*np.maximum(0,1-rho)**2/4)))
 strength=np.where(inside,strength,0)
 result=s.copy();result[...,0]=r-11*strength/16;result[...,1]=g+5*strength/16;result[...,2]=b+5*strength/16
 return np.clip(np.floor(result+.5),0,255).astype(np.uint8)

def analyze(root):
 generated=json.loads((root/'generate.json').read_text());cases=[c for c in generated['cases']if c['sourceDefinition']['group']=='continuous-gradient'];rows=[]
 centers=['roi','red-excess','red-maximum','red-green','red-blue','red-ratio-green','red-ratio-blue','red-ratio-greenblue','excess-ratio-green','excess-ratio-blue','excess-ratio-greenblue','red-green-ratio-green','red-green-ratio-greenblue','red-ratio-rgb','red-maximum-ratio-maximum','red-ratio-maximum']
 formulae=['mixture-mean','z-excess','red-green-excess','red-blue-excess','red-ratio-green','red-ratio-blue','red-ratio-greenblue']
 radial=['z','red-green','red-blue','ratio-green','ratio-blue']
 for c in cases:
  sdata=(root/('atlas-'+c['atlas']+'.rgba')).read_bytes();odata=(root/('replay-v1-'+c['atlas']+'.rgba')).read_bytes();s=np.frombuffer(sdata,np.uint8).reshape(32,32,4).astype(float);o=np.frombuffer(odata,np.uint8).reshape(32,32,4);Y,X=np.mgrid[:32,:32];candidates=[]
  for center in centers:
   if center=='roi':cx=cy=15.5
   else:
    scores=weights(s,center);total=scores.sum();cx=(X*scores).sum()/total;cy=(Y*scores).sum()/total
    # Preserve exact reflection symmetry of a source-derived weighting. Tiny
    # reduction-order errors must not move an exact atan2 sector boundary.
    if np.all(scores==scores[0:1,:]):cy=15.5
    if np.all(scores==scores[:,0:1]):cx=15.5
   for rounding in ['none','nearest-half']:
    if rounding=='nearest-half':cx,cy=round(cx*2)/2,round(cy*2)/2
    for shape in ['roi-radius','nearest-edge-circle']:
     radius=15.5 if shape=='roi-radius'else min(cx,31-cx,cy,31-cy)
     if radius<=0:continue
     for f in formulae:
      for rh in radial:
       p=predict(s,cx,cy,radius,radius,f,rh);delta=np.max(abs(p.astype(int)-o.astype(int)),axis=2)
       candidates.append(dict(center=center,rounding=rounding,cx=cx,cy=cy,radius=radius,radiusPolicy=shape,angular=f,radialExcess=rh,pixelsExceedingOne=int(np.sum(delta>1)),maxByteDelta=int(delta.max()),absoluteByteError=int(np.sum(abs(p.astype(int)-o.astype(int))))))
  outside=np.hypot((X-15.5)/15.5,(Y-15.5)/15.5)>=1;unchanged=np.max(abs(s-o),axis=2)>1
  ranked=sorted(candidates,key=lambda q:(q['pixelsExceedingOne'],q['absoluteByteError']))
  rows.append(dict(name=c['name'],sourceDefinition=c['sourceDefinition'],sourceSHA256=digest(sdata),nativeFileSHA256=digest(odata),comparedPixels=1024,fixedROIEllipseChangedPixelsOutside=int(np.sum(outside&unchanged)),candidateCount=len(candidates),bestDiagnostics=ranked[:20],allCandidates=candidates))
 return dict(qualification='Source-derived hypotheses with no fitted coordinates, coefficients or per-case choice. All full-buffer failures retained. Current bins use each proposed ellipse; glint omitted for gradients because the row-major minimum-ratio source lies outside its supplied central acceptance region. No source/fixture/renderer changes.',observationMode='replay-v1',formulae=formulae,radialExcessPolicies=radial,sourceCenterRecipes=centers,cases=rows)
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('artifact',type=Path);p.add_argument('output',type=Path);a=p.parse_args();report=analyze(a.artifact);a.output.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps([dict(name=c['name'],outside=c['fixedROIEllipseChangedPixelsOutside'],best=c['bestDiagnostics'][0])for c in report['cases']]))
