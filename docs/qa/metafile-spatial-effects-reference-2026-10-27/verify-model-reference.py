#!/usr/bin/env python3
"""Verify native RedEye model capture before consuming any numerical evidence."""
import argparse,hashlib,json
from pathlib import Path

def sha(data):return hashlib.sha256(data).hexdigest()
def verify(root):
    hashes=json.loads((root/'hashes.json').read_text(encoding='utf-8-sig'))
    for row in hashes:
        target=(root/row['file']).resolve()
        if not target.is_relative_to(root.resolve()):raise ValueError('member path')
        data=target.read_bytes()
        if len(data)!=row['bytes'] or sha(data)!=row['sha256'].lower():raise ValueError('member identity '+row['file'])
    inputs=json.loads((root/'input-hashes.json').read_text(encoding='utf-8-sig'))
    source_hashes=[]
    for row in inputs:
        if row['file'].endswith('.exe'):continue
        data=Path(row['file']).read_bytes();normalized=data.replace(b'\r\n',b'\n');windows=normalized.replace(b'\n',b'\r\n')
        if sha(windows)!=row['sha256'].lower():raise ValueError('Windows source identity '+row['file'])
        source_hashes.append(dict(file=row['file'],localSHA256=sha(data),windowsCRLFSHA256=sha(windows),normalization='LF to CRLF matches Windows checkout hash'))
    manifests={name:json.loads((root/(name+'.json')).read_text(encoding='utf-8-sig'))for name in ['generate','direct-v1','replay','replay-v1']}
    names=None;statuses=0;buffers=0;source_pairs=0
    for mode,d in manifests.items():
        if (d['caseCount'],d['plannedCaseCount'],d['controlCount'],len(d['cases']),len(d['atlases']))!=(29,27,2,29,29):raise ValueError('inventory '+mode)
        keys={c['atlas']for c in d['cases']}
        if names is not None and keys!=names:raise ValueError('case keys '+mode)
        names=keys
        for c in d['cases']:
            if c.get('error'):raise ValueError('native exception')
            if mode in ['generate','direct-v1']:
                for stage in ['direct','created']:
                    q=c[stage]
                    for field in ['setParametersStatus','applyStatus']:
                        if q[field]!=0:raise ValueError('SDK '+field)
                        statuses+=1
                    data=(root/q['rgba']).read_bytes()
                    if q['width']!=32 or q['height']!=32 or len(data)!=4096:raise ValueError('SDK extent')
                    if stage=='created' and q['outputRect']!=[0,0,32,32]:raise ValueError('created output origin')
                    buffers+=1
                if mode=='generate':
                    for field in ['recordSetParametersStatus','recordCreateStatus','recordStatus']:
                        if c[field]!=0:raise ValueError('record '+field)
                        statuses+=1
            else:
                for field in ['bitmapLoadStatus','drawStatus']:
                    if c[field]!=0:raise ValueError('file '+field)
                    statuses+=1
                if not c['expectedSize'] or (c['width'],c['height'],c['intrinsicWidth'],c['intrinsicHeight'])!=(32,32,32,32):raise ValueError('file extent')
                for q in [c,c['intrinsic']]:
                    if len((root/q['rgba']).read_bytes())!=4096:raise ValueError('file bytes')
                    buffers+=1
        if mode in ['generate','direct-v1']:
            for atlas in d['atlases']:
                data=(root/atlas['rgba']).read_bytes();requested=(root/atlas['rgba'].replace('.rgba','-requested.rgba')).read_bytes()
                if not atlas['requestedMatchesObserved'] or data!=requested or len(data)!=4096:raise ValueError('actual source mismatch')
                source_pairs+=1
    if (statuses,buffers,source_pairs)!=(435,232,58):raise ValueError('verification counts')
    for name in names:
        if (root/('atlas-'+name+'.rgba')).read_bytes()!=(root/('atlas-direct-v1-'+name+'.rgba')).read_bytes():raise ValueError('startup source difference')
    return dict(verifiedMembers=len(hashes),statusCount=statuses,effectBuffers=buffers,sourceEqualityPairs=source_pairs,sourceStartupEqualityPairs=len(names),sourceHashes=source_hashes,sourceRevision=(root/'source-revision.txt').read_text(encoding='utf-8-sig').strip(),manifestSHA256={name:sha((root/(name+'.json')).read_bytes())for name in manifests})
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=Path);p.add_argument('output',type=Path);a=p.parse_args();report=verify(a.root);a.output.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:v for k,v in report.items()if k not in ['sourceHashes','manifestSHA256']}))
