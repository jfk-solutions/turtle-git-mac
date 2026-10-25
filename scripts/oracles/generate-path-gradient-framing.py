#!/usr/bin/env python3
# Original reference-only header/page-unit discrimination. Never edits inputs.
import struct
from pathlib import Path
p=Path('Tests/TurtleGitCoreTests/Fixtures/Metafile')
u=lambda *v:struct.pack('<'+'I'*len(v),*v)
def framed(raw,display=False,pixel=False,bound63=False):
 h=bytearray(raw[:88]);o=88;records=[]
 if bound63:struct.pack_into('<4i',h,8,0,0,63,63)
 while o<len(raw):
  typ,size=struct.unpack_from('<II',raw,o);record=raw[o:o+size]
  if typ==70 and record[12:16]==b'EMF+':
   cb=struct.unpack_from('<I',record,8)[0];stream=bytearray(record[16:12+cb])
   if display:struct.pack_into('<H',stream,2,0);struct.pack_into('<I',stream,16,1)
   if pixel:
    n=struct.unpack_from('<I',stream,4)[0]
    page=struct.pack('<HHIIf',0x4030,2,16,4,1)
    stream=stream[:n]+page+stream[n:]
   payload=b'EMF+'+stream;record=u(70,12+len(payload))+u(len(payload))+payload
  records.append(record);o+=size
 out=h+b''.join(records);struct.pack_into('<I',out,48,len(out));return out
base=(p/'path-gradient-square.emf').read_bytes()
for name,opts in [('page',{'pixel':True}),('display',{'display':True}),('bounds63',{'bound63':True}),('display-page',{'display':True,'pixel':True}),('display-bounds63',{'display':True,'bound63':True}),('display-page-bounds63',{'display':True,'pixel':True,'bound63':True})]:
 (p/('path-gradient-framing-probe-'+name+'.emf')).write_bytes(framed(base,**opts))
for src in list(p.glob('path-gradient-*.emf')):
 if 'refused-' in src.name or 'framing-' in src.name:continue
 for bound in [True]:
  (p/('path-gradient-framing-pixel'+('63-' if bound else '64-')+src.name[len('path-gradient-'):])).write_bytes(framed(src.read_bytes(),display=True,pixel=True,bound63=bound))
