# Original malformed/budget fixtures derived from the recorded explicit cubic. Run from repository root.
from pathlib import Path
import struct
p=Path('Tests/TurtleGitCoreTests/Fixtures/Metafile/GeneralPathGradient');original=(p/'explicit-cubic-uniform.emf').read_bytes()
for mode in ['open','flatten-budget']:
 d=bytearray(original);o=0
 while o+8<=len(d):
  typ,n=struct.unpack_from('<II',d,o)
  if typ==70 and d[o+12:o+16]==b'EMF+':
   z=o+16
   while z+12<=o+n:
    rt,fl,rs,ds=struct.unpack_from('<HHII',d,z)
    if rt==0x4008 and(fl>>8)&127==1:
     start=z+12;colors=struct.unpack_from('<I',d,start+28)[0];path=start+32+4*colors+4;count=struct.unpack_from('<I',d,path+4)[0];assert count==7
     if mode=='open':d[path+12+count*8+count-1]&=127
     else:
      for k in range(count*2):struct.pack_into('<f',d,path+12+4*k,struct.unpack_from('<f',d,path+12+4*k)[0]*1e6)
     before=struct.pack('<HHIIIIffff',0x400A,0x8000,36,24,0xffff0000,1,0,0,8,8);assert len(before)==36
     d[z:z]=before;struct.pack_into('<I',d,o+4,n+36);struct.pack_into('<I',d,o+8,struct.unpack_from('<I',d,o+8)[0]+36);struct.pack_into('<I',d,48,len(d));break
    z+=rs
   else:o+=n;continue
   break
  o+=n
 name='open-cubic-after-paint.emf' if mode=='open' else 'refused-cubic-flatten-budget-after-paint.emf'
 (p/name).write_bytes(d)
