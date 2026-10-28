#!/usr/bin/env python3
"""Recover source-region placement from original native observations only.

No application execution, per-case output lookup, or relaxed application oracle.
The Gaussian model's small numerical precision remains a separate qualification.
"""
import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('reference',type=Path)
parser.add_argument('--report',type=Path)
args=parser.parse_args()
spec=importlib.util.spec_from_file_location('spatial_model',Path(__file__).with_name('spatial-kernel-model.py'))
model=importlib.util.module_from_spec(spec);spec.loader.exec_module(model)
root=args.reference
manifest=json.loads((root/'generate.json').read_text())
assert manifest['caseCount']==12 and len(manifest['cases'])==12
records=[]
for case in manifest['cases']:
    name=case['name'];source=(root/('atlas-'+name+'.rgba')).read_bytes()
    width,height=case['sourceWidth'],case['sourceHeight']
    x,y,w,h=case['recordSourceRect'];tx,ty=case['recordImageMatrix'][4:]
    left,top=math.floor(x),math.floor(y)
    right,bottom=math.ceil(x+w)+1,math.ceil(y+h)+1
    assert case['directROI']==[left,top,right,bottom]
    contained=left>=0 and top>=0 and right<=width and bottom<=height
    cl,ct=max(0,left),max(0,top);cr,cb=min(width,right),min(height,bottom)
    cropped=b''.join(source[(row*width+cl)*4:(row*width+cr)*4] for row in range(ct,cb))
    expand=case['parameters']['expandEdge']
    raw,mw,mh,ox,oy=model.blur(cropped,cr-cl,cb-ct,case['parameters']['radius'],expand and not contained,edge='zero' if expand else 'mirror')
    created=case['created'];expected=(root/created['rgba']).read_bytes()
    ow,oh=created['width'],created['height'];ol,ot,orr,ob=created['outputRect']
    assert [ow,oh]==[orr-ol,ob-ot]
    predicted=bytearray(ow*oh*4)
    for row in range(oh):
        for col in range(ow):
            sx,sy=col+ol-cl-ox,row+ot-ct-oy
            if 0<=sx<mw and 0<=sy<mh:
                predicted[(row*ow+col)*4:(row*ow+col)*4+4]=raw[(sy*mw+sx)*4:(sy*mw+sx)*4+4]
    deltas=[abs(a-b) for a,b in zip(predicted,expected)]
    # File placement is derived from the native created output, separating the
    # exact region/association contract from the approximate Gaussian arithmetic.
    normalized=model.normalize(model.normalize(expected))
    for mode in ['replay','replay-v1']:
        playback=json.loads((root/(mode+'.json')).read_text())
        item=next(c for c in playback['cases'] if c['emf']==case['emf'])
        fw,fh=item['width'],item['height'];actual=(root/item['rgba']).read_bytes();painted=bytearray(fw*fh*4)
        for row in range(max(0,math.ceil(y+ty)),min(fh,math.ceil(y+h+ty))):
            for col in range(max(0,math.ceil(x+tx)),min(fw,math.ceil(x+w+tx))):
                sx,sy=int(col-tx-ol),int(row-ty-ot)
                if 0<=sx<ow and 0<=sy<oh:painted[(row*fw+col)*4:(row*fw+col)*4+4]=normalized[(sy*ow+sx)*4:(sy*ow+sx)*4+4]
        assert painted==actual,(name,mode,'native created -> file placement differs')
    records.append(dict(name=name,source_sha256=hashlib.sha256(source).hexdigest(),created_sha256=hashlib.sha256(expected).hexdigest(),contained=contained,model_max=max(deltas),model_channels_over_one=sum(v>1 for v in deltas),native_created_to_file='exact-full-RGBA-both-startup-versions'))
report=dict(scope='Source contract analysis, not Mac Core/native acceptance',reference_run=40521022045,archive_sha256='6ebfc19d2aca08b480d5b4790930a0fc0214b864b09192fb6f2748a46dafb810',cases=records,qualification='Contained and full-crossing ROIs measured. Arbitrary far-outside/negative ROI profiles and general effect numerical kernels remain separate.')
if args.report:args.report.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(dict(cases=len(records),model_max=max(r['model_max'] for r in records),channels_over_one=sum(r['model_channels_over_one'] for r in records),native_file_placements_exact=len(records)*2)))
