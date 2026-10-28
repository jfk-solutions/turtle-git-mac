#!/usr/bin/env python3
"""Connected-region/moment geometry hypotheses, scored on original full buffers.

One red/green contrast definition is fixed across every image. No source case
name, observed output coordinate or fitted constant chooses the region/model.
The current numerical correction component is deliberately held fixed; a
failure therefore rejects the combined hypothesis, not geometry in isolation.
"""
import argparse,hashlib,json,math,importlib.util
from pathlib import Path
import numpy as np

def sha(b):return hashlib.sha256(b).hexdigest()
def components(mask,connectivity):
 h,w=mask.shape;labels=np.full((h,w),-1,int);groups=[]
 offsets=[(-1,0),(1,0),(0,-1),(0,1)]
 if connectivity==8:offsets += [(-1,-1),(-1,1),(1,-1),(1,1)]
 for y in range(h):
  for x in range(w):
   if not mask[y,x]or labels[y,x]>=0:continue
   label=len(groups);todo=[(x,y)];labels[y,x]=label;group=[]
   while todo:
    px,py=todo.pop();group.append((px,py))
    for dx,dy in offsets:
     nx,ny=px+dx,py+dy
     if 0<=nx<w and 0<=ny<h and mask[ny,nx]and labels[ny,nx]<0:labels[ny,nx]=label;todo.append((nx,ny))
   groups.append(group)
 return labels,groups

def moment(weights,X,Y,fallback):
 total=weights.sum()
 if total<=0:return fallback
 cx=float((weights*X).sum()/total);cy=float((weights*Y).sum()/total)
 if np.all(weights==weights[0:1,:]):cy=(weights.shape[0]-1)/2
 if np.all(weights==weights[:,0:1]):cx=(weights.shape[1]-1)/2
 vx=float((weights*(X-cx)**2).sum()/total);vy=float((weights*(Y-cy)**2).sum()/total)
 return cx,cy,vx,vy

def predict(s,area,recipe,connectivity):
 height,width,_=s.shape;X,Y=np.meshgrid(np.arange(width),np.arange(height));left,top,right,bottom=area;region=(X>=left)&(X<right)&(Y>=top)&(Y<bottom)
 cx0=(left+right-1)/2;cy0=(top+bottom-1)/2;rx0=(right-left-1)/2;ry0=(bottom-top-1)/2
 rr,gg,bb=s[...,0],s[...,1],s[...,2]
 contrast=np.maximum(0,np.divide(rr,gg,out=np.zeros_like(rr),where=gg>0)-1);contrast=np.where(region,contrast,0)
 labels,groups=components(contrast>0,connectivity)
 reference=moment(region.astype(float),X,Y,(cx0,cy0,1,1));mx,my,vx,vy=moment(contrast,X,Y,reference)
 if recipe=='accepted-contrast-centroid':
  # Reuse the independently observed central2/3 eligibility boundary as a
  # new, explicitly unaccepted detector hypothesis, never an observed fit.
  if math.hypot((mx-cx0)/rx0,(my-cy0)/ry0)>2/3:mx,my=cx0,cy0
  radius=min(mx-left,right-1-mx,my-top,bottom-1-my)
  plans=[(mx,my,max(.5,radius),max(.5,radius),region)]
 elif recipe=='original-ROI':plans=[(cx0,cy0,rx0,ry0,region)]
 elif recipe=='contrast-centroid-nearest-edge':
  radius=min(mx-left,right-1-mx,my-top,bottom-1-my)
  plans=[(mx,my,max(.5,radius),max(.5,radius),region)]
 elif recipe=='contrast-covariance':plans=[(mx,my,rx0*math.sqrt(max(0,vx)/reference[2]),ry0*math.sqrt(max(0,vy)/reference[3]),region)]
 else:
  plans=[];selected=groups
  if recipe=='largest-connected-region':selected=sorted(groups,key=len,reverse=True)[:1]
  for group in selected:
   label=labels[group[0][1],group[0][0]];mask=labels==label
   cx,cy,cvx,cvy=moment(np.where(mask,contrast,0),X,Y,reference)
   if recipe=='connected-covariance':rx=rx0*math.sqrt(max(0,cvx)/reference[2]);ry=ry0*math.sqrt(max(0,cvy)/reference[3])
   else:
    # Component source bounds supply the equivalent filled rectangular pupil;
    # all components use identical bounds/center algebra.
    xs,ys=zip(*group);rx=(max(xs)-min(xs))/2;ry=(max(ys)-min(ys))/2
   plans.append((cx,cy,max(.5,rx),max(.5,ry),mask))
  if not plans:plans=[(cx0,cy0,rx0,ry0,region)]
 strength=np.zeros_like(rr);z=np.maximum(0,rr-(gg+bb)/2);M=np.maximum(0,rr-np.maximum(gg,bb))
 safe=lambda a,b:np.divide(a,b,out=np.zeros_like(a),where=b!=0)
 for cx,cy,rx,ry,mask in plans:
  if rx<=0 or ry<=0:continue
  rho=np.hypot((X-cx)/rx,(Y-cy)/ry);inside=(rho<1)&region
  angle=(np.degrees(np.arctan2(Y-cy,X-cx))%360//6).astype(int)
  # Retain original authored ROI as the sampling domain. Connected-region
  # detection controls correction support, not filesystem or source authority.
  statistics=inside if recipe=='accepted-contrast-centroid'else(np.hypot((X-cx0)/rx0,(Y-cy0)/ry0)<1)&region
  means=np.zeros((60,4))
  for k in range(60):
   q=statistics&(angle==k)
   if q.any():means[k]=[rr[q].mean(),gg[q].mean(),bb[q].mean(),z[q].mean()]
  mg,mb,mz=[means[angle,k]for k in [1,2,3]];h=safe(z-mz,z);dg,db=mg-gg,mb-bb
  floor=np.where(h>0,M*np.maximum(0,h+safe((1-h)*abs(dg)*dg*db,mg*(abs(dg)*mb+abs(db)*mg))),0)
  radial=M*(h+(1-h)*np.maximum(0,1-rho)**2/4)
  value=np.maximum(0,np.maximum(floor,radial));strength=np.maximum(strength,np.where(inside&mask,value,0))
 # The already qualified local gray-hole glint hypothesis remains separate.
 ratios=np.divide(rr,gg,out=np.full_like(rr,np.inf),where=gg>0);ratios=np.where(region,ratios,np.inf)
 if np.isfinite(ratios).any():
  sy,sx=np.unravel_index(np.argmin(ratios),ratios.shape)
  if math.hypot((sx-cx0)/rx0,(sy-cy0)/ry0)<=2/3:
   strength=np.maximum(strength,np.where(region,np.maximum(0,M-5*((X-sx)**2+(Y-sy)**2)),0))
 output=s.copy();output[...,0]=rr-11*strength/16;output[...,1]=gg+5*strength/16;output[...,2]=bb+5*strength/16
 return np.clip(np.floor(output+.5),0,255).astype(np.uint8),dict(contrastCenter=[mx,my],contrastVariance=[vx,vy],componentCount=len(groups),componentSizes=sorted([len(g)for g in groups],reverse=True),geometry=[dict(center=[p[0],p[1]],radii=[p[2],p[3]],supportedPixels=int(p[4].sum()))for p in plans]),labels,groups

def source_index(artifacts):
 result={}
 for manifest in artifacts.glob('*/generate.json'):
  try:d=json.loads(manifest.read_text(encoding='utf-8-sig'))
  except (ValueError,UnicodeError):continue
  for item in d.get('cases',[])+([d['baseline']]if 'baseline'in d else[]):
   emf=manifest.parent/item.get('emf',item['name']+'.emf')
   atlas=manifest.parent/('atlas-'+item.get('atlas',item['name'])+'.rgba')
   if emf.exists()and atlas.exists():result[sha(emf.read_bytes())]=(manifest.parent,item,atlas)
 return result

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('fixture',type=Path);p.add_argument('artifacts',type=Path);p.add_argument('output',type=Path);a=p.parse_args()
 manifest=json.loads((a.fixture/'windows-reference.json').read_text());index=source_index(a.artifacts);rows=[];skips=[]
 recipes=['accepted-contrast-centroid','original-ROI','contrast-centroid-nearest-edge','contrast-covariance','largest-connected-region','all-connected-bounds','connected-covariance']
 for case in manifest['cases']:
  if case['family']!='redEyeCorrection':continue
  if case['sourceSHA256']not in index:skips.append(dict(file=case['file'],reason='original source atlas unavailable'));continue
  root,item,atlas=index[case['sourceSHA256']];w=case['width'];h=case['height'];data=atlas.read_bytes()
  if len(data)!=w*h*4:skips.append(dict(file=case['file'],reason='source/file frame dimensions differ'));continue
  s=np.frombuffer(data,np.uint8).reshape(h,w,4).astype(float);expected=(a.fixture/case['referenceRGBA']).read_bytes();assert sha(expected)==case['rgbaSHA256'];o=np.frombuffer(expected,np.uint8).reshape(h,w,4)
  areas=case['parameters']['areas']
  if len(areas)!=1 or not np.all(s[...,3]==255):skips.append(dict(file=case['file'],reason='requires multiple-area or nonopaque contract'));continue
  left,top,right,bottom=areas[0]
  if not(0<=left<right<=w and 0<=top<bottom<=h)or right-left<2 or bottom-top<2:skips.append(dict(file=case['file'],reason='requires clipped/outside/degenerate area contract'));continue
  predictions=[];topology=[]
  for connectivity in [4,8]:
   for recipe in recipes:
    pred,geometry,labels,groups=predict(s,areas[0],recipe,connectivity);delta=np.max(abs(pred.astype(int)-o.astype(int)),axis=2)
    predictions.append(dict(recipe=recipe,connectivity=connectivity,pixelsExceedingOne=int(np.sum(delta>1)),maxByteDelta=int(delta.max()),absoluteByteError=int(np.sum(abs(pred.astype(int)-o.astype(int)))),geometry=geometry))
   changed=np.max(abs(s-o),axis=2)>1
   topology.append(dict(connectivity=connectivity,componentCount=len(groups),changedComponents=sum(any(changed[y,x]for x,y in group)for group in groups),largestComponentPixels=max(map(len,groups),default=0)))
  rows.append(dict(file=case['file'],sourceAtlas=str(atlas),sourceSHA256=sha(data),referenceSHA256=case['rgbaSHA256'],dimensions=[w,h],area=areas[0],topology=topology,predictions=predictions))
 report=dict(qualification='Full-buffer geometry/composition hypotheses, not an accepted detector or application test. The same contrast/connected-component recipes apply to every admitted opaque single-area reference. All excluded contracts remain explicitly open; no shipping scope narrows.',contrast='w=max(0,R/G-1); G=0 contributes zero; no positive weights falls back to original ROI geometry.',recipes=recipes,sourceManifestSHA256=sha((a.fixture/'windows-reference.json').read_bytes()),admittedCases=len(rows),skipped=skips,cases=rows)
 a.output.write_text(json.dumps(report,indent=2)+'\n')
 print(json.dumps(dict(admitted=len(rows),skipped=len(skips),scores={recipe:dict(passingCases=sum(next(q for q in c['predictions']if q['recipe']==recipe and q['connectivity']==4)['pixelsExceedingOne']==0 for c in rows),badPixels=sum(next(q for q in c['predictions']if q['recipe']==recipe and q['connectivity']==4)['pixelsExceedingOne']for c in rows))for recipe in recipes})))
if __name__=='__main__':main()
