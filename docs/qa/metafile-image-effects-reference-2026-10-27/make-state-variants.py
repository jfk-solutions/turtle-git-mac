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
def emit(name,keep_serials=None,force_e=None,clear_first=False,prefix_first=()):
    records=[]
    for i,r in enumerate(plus):
        t,f=struct.unpack_from('<HH',r)
        if t==0x4038 and keep_serials is not None and i not in keep_serials:continue
        if t in (0x401a,0x401b) and force_e is not None:
            r=bytearray(r);struct.pack_into('<H',r,2,(f|0x2000) if force_e else (f&~0x2000));r=bytes(r)
        if i==draws[0]:
            records.extend(prefix_first)
            if clear_first:
                r=bytearray(r);struct.pack_into('<H',r,2,struct.unpack_from('<H',r,2)[0]&~0x2000);r=bytes(r)
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
    manifest['variants'].append({'name':name,'sha256':hashlib.sha256(out).hexdigest(),'keepSerializableIndices':None if keep_serials is None else sorted(keep_serials),'forceE':force_e,'clearFirstE':clear_first,'prefixFirstTypes':[hex(struct.unpack_from('<H',r)[0]) for r in prefix_first]})
emit('state-all-native-serials-E',None,True)
emit('state-first-effect-persists',{serials[0]},True)
emit('state-two-effects-save-restore',{serials[0],serials[1]},True)
emit('state-effect-nonE-ignored',None,False)
emit('state-E-without-effect',set(),True)
# A genuinely plain DrawImagePoints immediately before the first E draw. The
# recorder's plain DrawImage record is not a substitute: its E bit is reserved.
plain=bytearray(plus[draws[0]])
kind,flags=struct.unpack_from('<HH',plain)
if kind!=0x401b or not flags&0x4000 or flags&0x800:raise ValueError('Expected native absolute compressed DrawImagePoints')
if u32(plain,36)!=3:raise ValueError('Expected three native destination points')
struct.pack_into('<H',plain,2,flags&~0x2000)
for point in range(3):
 y=struct.unpack_from('<h',plain,42+point*4)[0]
 struct.pack_into('<h',plain,42+point*4,y+4)
emit('pending-effect-across-plain-draw',{serials[0]},True,prefix_first=(bytes(plain),))
save=next(r for r in plus if struct.unpack_from('<H',r)[0]==0x4025)
restore=next(r for r in plus if struct.unpack_from('<H',r)[0]==0x4026)
container=next(r for r in plus if struct.unpack_from('<H',r)[0]==0x4028)
end_container=next(r for r in plus if struct.unpack_from('<H',r)[0]==0x4029)
emit('pending-effect-save-restore-before-E',{serials[0]},True,prefix_first=(save,restore))
emit('pending-effect-container-before-E',{serials[0]},True,prefix_first=(container,end_container))
(root/'wire-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
