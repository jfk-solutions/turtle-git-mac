#!/usr/bin/env python3
"""Independent spatial-mask hypothesis experiment; no production or pixel oracle.

Fits linear diagnostic ray features to several nonlinear transforms of observed
correction. Coefficients are diagnostic only, not a general shipping algorithm.
"""
import argparse, hashlib, json
from pathlib import Path
import numpy as np

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();root=args.artifact
    manifest=root/'generate.json';doc=json.loads(manifest.read_text());sources={a['name']:a for a in doc['atlases']}
    features=[];nonlinear_features=[];actual=[];identities=[];hashes={manifest.name:hashlib.sha256(manifest.read_bytes()).hexdigest()}
    for c in doc['cases']:
        if c['family']!='redEyeCorrection' or c['parameters']['areas']!=[[0,0,32,32]]:continue
        definition=c['sourceDefinition'];name=c['source']
        if definition['shape']not in ('solid','square','disk')or definition['foregroundRGB']!=[240,20,10]:continue
        if c['sourceWidth']!=32 or c['sourceHeight']!=32 or 'shift'in name or '-at'in name or 'repeat'in name:continue
        if c['direct'].get('applyStatus')!=0:raise ValueError('unexpected native refusal')
        paths=[root/sources[c['atlas']]['rgba'],root/c['direct']['rgba']]
        buffers=[]
        for path in paths:
            data=path.read_bytes();hashes[path.name]=hashlib.sha256(data).hexdigest();buffers.append(np.frombuffer(data,np.uint8).reshape(32,32,4).astype(float))
        source,out=buffers;score=np.maximum(0,source[:,:,0]-np.maximum(source[:,:,1],source[:,:,2]))/220
        for y in range(32):
            for x in range(32):
                if score[y,x]==0:continue
                row=[1.]
                for group in [[(1,1),(-1,-1),(1,-1),(-1,1)],[(1,0),(-1,0),(0,1),(0,-1)]]:
                    for distance in range(1,32):
                        row.append(sum(score[y+dy*distance,x+dx*distance]for dx,dy in group if 0<=x+dx*distance<32 and 0<=y+dy*distance<32))
                nonlinear=[1.]
                for distance in range(1,32):
                    rays=[]
                    for dx,dy in [(1,1),(1,-1),(1,0),(0,1)]:
                        rays.append(sum(score[y+sign*dy*distance,x+sign*dx*distance]for sign in (-1,1)if 0<=x+sign*dx*distance<32 and 0<=y+sign*dy*distance<32))
                    nonlinear.extend([sum(rays[:2]),max(rays[:2]),rays[0]*rays[1],sum(rays[2:]),max(rays[2:]),rays[2]*rays[3]])
                nonlinear_features.append(nonlinear)
                features.append(row);actual.append(source[y,x,0]-out[y,x,0]);identities.append([name,x,y])
    q=np.array([max(0.,1-np.hypot((x-15.5)/15.5,(y-15.5)/15.5))/2 for _,x,y in identities]);
    matrices={"symmetric_linear":np.array(features),"nonlinear_ray_pair":np.array(nonlinear_features),"symmetric_plus_roi_cone":np.column_stack([features,q]),"nonlinear_plus_roi_cone":np.column_stack([nonlinear_features,q])};dr=np.array(actual);results={}
    for label,target,inverse in [
        ('linear',dr,lambda t:t),
        ('sqrt',np.sqrt(dr/(220*11/16)),lambda t:np.square(t)*(220*11/16)),
        ('fourth_root',np.power(dr/(220*11/16),.25),lambda t:np.power(t,4)*(220*11/16)),
    ]:
        results[label]={}
        for design,a in matrices.items():
            count=a.shape[1]
            weights,_,rank,_=np.linalg.lstsq(a,target,rcond=None)
            prediction=inverse(a@weights);error=np.abs(prediction-dr)
            indices=np.argsort(error)[-8:]
            results[label][design]={'rank':int(rank),'rows':len(dr),'redDeltaRMSE':float(np.sqrt(np.mean(error**2))),'redDeltaMax':float(error.max()),'above1':int(np.sum(error>1)), 'diagnosticCoefficients':weights.tolist(),'worst':[dict(identity=identities[i],actual=float(dr[i]),predicted=float(prediction[i]))for i in indices]}
    args.output.write_text(json.dumps({'qualification':'Diagnostic regression only. No production algorithm or acceptance tolerance is established. Centered shapes only; per-distance fitted coefficients must not be shipped.','results':results,'inputSHA256':hashes},indent=2)+'\n')
    print(json.dumps({k:{n:{q:v[q]for q in ('redDeltaRMSE','redDeltaMax','above1')}for n,v in fits.items()}for k,fits in results.items()},indent=2))
if __name__=='__main__':main()
