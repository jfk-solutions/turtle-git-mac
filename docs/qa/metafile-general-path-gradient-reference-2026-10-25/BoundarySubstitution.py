# Original synthetic oracle boundary substitution; input recorded EMF directory, output directory.
from pathlib import Path
import struct,json,hashlib,sys
src=Path(sys.argv[1])
out=Path(sys.argv[2]);out.mkdir(exist_ok=True)
cubic=[(8.5,32.5),(8.5,.5),(56.5,8.5),(56.5,32.5),(56.5,60.5),(8.5,48.5),(8.5,32.5)]
disjoint=[(6.5,8.5),(28.5,8.5),(28.5,52.5),(6.5,52.5),(36.5,16.5),(58.5,16.5),(58.5,48.5),(36.5,48.5)]
receipts=[]
for stem in ['cubic-uniform','cubic-multi','disjoint-ab']:
 name='native-general-'+stem+'.emf';d=bytearray((src/name).read_bytes());points=disjoint if stem=='disjoint-ab' else cubic;types=[0,1,1,129,0,1,1,129] if stem=='disjoint-ab' else [0,3,3,3,3,3,131]
 path=struct.pack('<III',0xdbc01002,len(points),0)+b''.join(struct.pack('<ff',*p) for p in points)+bytes(types);path+=b'\0'*((-len(path))%4)
 o=0;found=0
 while o+8<=len(d):
  typ,size=struct.unpack_from('<II',d,o)
  if typ==70 and d[o+12:o+16]==b'EMF+':
   z=o+16
   while z+12<=o+size:
    rt,flags,rs,ds=struct.unpack_from('<HHII',d,z)
    if rt==0x4008 and (flags>>8)&127==1:
     payload=bytes(d[z+12:z+12+ds]);count=struct.unpack_from('<I',payload,28)[0];begin=32+count*4;n=struct.unpack_from('<I',payload,begin)[0];end=begin+4+8*n
     assert struct.unpack_from('<I',payload,8)[0]==0
     q=bytearray(payload[:begin]);struct.pack_into('<I',q,8,1);q+=struct.pack('<I',len(path))+path+payload[end:]
     r=struct.pack('<HHII',rt,flags,12+len(q),len(q))+q;delta=len(r)-rs
     d[z:z+rs]=r;struct.pack_into('<I',d,o+4,size+delta);struct.pack_into('<I',d,o+8,struct.unpack_from('<I',d,o+8)[0]+delta)
     found+=1;break
    z+=rs
   if found:break
  o+=size
 assert found==1
 struct.pack_into('<I',d,48,len(d));target=out/('explicit-'+stem+'.emf');target.write_bytes(d)
 receipts.append({'file':target.name,'recordedSource':name,'recordedSHA256':hashlib.sha256((src/name).read_bytes()).hexdigest(),'explicitSHA256':hashlib.sha256(d).hexdigest(),'originalBoundaryCount':n,'originalSurroundCountPreserved':count,'suppliedPoints':points,'suppliedTypes':types,'change':'Only brush boundary point-array replaced with original EmfPlusPath, flag and enclosing lengths/nBytes updated; all colors/transforms/draw records preserved'})
(out/'substitutions.json').write_text(json.dumps(receipts,indent=2)+'\n')
