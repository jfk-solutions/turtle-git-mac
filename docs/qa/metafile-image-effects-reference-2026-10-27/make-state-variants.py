#!/usr/bin/env python3
"""Mutate only recorded EMF+ effect references; retain actual native objects/draw payloads."""
import hashlib,json,struct,sys
from pathlib import Path
u32=lambda b,o:struct.unpack_from('<I',b,o)[0]
root=Path(sys.argv[1]);source=(root/'state-seed.emf').read_bytes()
outer=[];plus=[];offset=0
while offset<len(source):
    kind,size=struct.unpack_from('<II',source,offset)
    if size<8 or size%4 or offset+size>len(source):raise ValueError('outer framing')
    record=source[offset:offset+size];offset+=size
    if kind==70 and size>=16 and record[12:16]==b'EMF+':
        data=record[16:12+u32(record,8)];p=0
        while p<len(data):
            t,f,n,d=struct.unpack_from('<HHII',data,p)
            if n<12 or n%4 or d>n-12 or p+n>len(data):raise ValueError('plus framing')
            plus.append(data[p:p+n]);p+=n
    else:outer.append(record)
if offset!=len(source):raise ValueError('extent')
serials=[i for i,r in enumerate(plus) if struct.unpack_from('<H',r)[0]==0x4038]
draws=[i for i,r in enumerate(plus) if struct.unpack_from('<H',r)[0] in (0x401a,0x401b)]
if len(serials)<2 or len(draws)<6:raise ValueError(f'Native recorder did not serialize expected effects: serials={serials},draws={draws}')
manifest={'seedSHA256':hashlib.sha256(source).hexdigest(),'records':[{'index':i,'type':hex(struct.unpack_from('<H',r)[0]),'flags':hex(struct.unpack_from('<H',r,2)[0]),'size':len(r)}for i,r in enumerate(plus)],'variants':[]}
def emit(name,keep_serials=None,force_e=None):
    records=[]
    for i,r in enumerate(plus):
        t,f=struct.unpack_from('<HH',r)
        if t==0x4038 and keep_serials is not None and i not in keep_serials:continue
        if t in (0x401a,0x401b) and force_e is not None:
            r=bytearray(r);struct.pack_into('<H',r,2,(f|0x2000) if force_e else (f&~0x2000));r=bytes(r)
        records.append(r)
    comments=[]
    for r in records:
        body=b'EMF+'+r;comments.append(struct.pack('<III',70,12+len(body),len(body))+body)
    # Native seed is EMF+ Only: keep non-comment records exactly, insert at first comment position.
    result=[];inserted=False;off=0
    while off<len(source):
        typ,n=struct.unpack_from('<II',source,off);r=source[off:off+n];off+=n
        if typ==70 and r[12:16]==b'EMF+':
            if not inserted:result.extend(comments);inserted=True
        else:result.append(r)
    header=bytearray(result[0]);struct.pack_into('<II',header,48,sum(map(len,result)),len(result));result[0]=bytes(header)
    out=b''.join(result);(root/(name+'.emf')).write_bytes(out)
    manifest['variants'].append({'name':name,'sha256':hashlib.sha256(out).hexdigest(),'keepSerializableIndices':None if keep_serials is None else sorted(keep_serials),'forceE':force_e})
emit('state-all-native-serials-E',None,True)
emit('state-first-effect-persists',{serials[0]},True)
emit('state-two-effects-save-restore',{serials[0],serials[1]},True)
emit('state-effect-nonE-ignored',None,False)
emit('state-E-without-effect',set(),True)
(root/'wire-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
