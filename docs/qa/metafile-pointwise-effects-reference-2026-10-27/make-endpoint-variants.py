#!/usr/bin/env python3
"""Replace only a measured valid ColorCurve intensity to assay SDK-rejected endpoints.

Original generate/direct manifests are not changed: missing-file BitmapLoad2 is
not evidence that a derived endpoint EMF is rejected by native file playback.
"""
import hashlib,json,struct,sys,uuid
from pathlib import Path
source=Path(sys.argv[1]);out=Path(sys.argv[2])if len(sys.argv)>2 else source
out.mkdir(parents=True,exist_ok=True)
guid=uuid.UUID('DD6A0022-58E4-4A67-9D9B-D48EB881A53D').bytes_le
sha=lambda b:hashlib.sha256(b).hexdigest()
rows=[]
for mode,valid,endpoint in [(6,1,0),(7,254,255)]:
 for channel in range(4):
  parent=f'curve-{mode}-{channel}-{valid}.emf';name=f'curve-{mode}-{channel}-{endpoint}.emf'
  original=(source/parent).read_bytes();wire=bytearray(original);offset=0;changed=0
  while offset<len(wire):
   if offset+8>len(wire):raise ValueError('outer header')
   kind,size=struct.unpack_from('<II',wire,offset)
   if size<8 or size%4 or offset+size>len(wire):raise ValueError('outer size')
   if kind==70 and size>=16 and wire[offset+12:offset+16]==b'EMF+':
    cb=struct.unpack_from('<I',wire,offset+8)[0]
    if cb<4 or cb>size-12:raise ValueError('comment extent')
    p=offset+16;end=offset+12+cb
    while p<end:
     t,flags,n,data=struct.unpack_from('<HHII',wire,p)
     if n<12 or n%4 or p+n>end or data>n-12:raise ValueError('plus framing')
     if t==0x4038 and wire[p+12:p+28]==guid:
      if n!=44 or data!=32 or struct.unpack_from('<I',wire,p+28)[0]!=12:raise ValueError('curve size')
      if struct.unpack_from('<IIi',wire,p+32)!=(mode,channel,valid):raise ValueError('unexpected source parameters')
      struct.pack_into('<i',wire,p+40,endpoint);changed+=1
     p+=n
   offset+=size
  if changed!=1:raise ValueError(f'Expected exactly one source effect, found {changed}: {parent}')
  wire=bytes(wire)
  target=out/name
  if target.exists() and target.read_bytes()!=wire:raise ValueError('Refusing to overwrite different original endpoint wire '+name)
  target.write_bytes(wire)
  rows.append(dict(file=name,source=parent,sourceSHA256=sha(original),sourceParameters=dict(adjustment=mode,channel=channel,adjustValue=valid),parameters=dict(adjustment=mode,channel=channel,adjustValue=endpoint),sourceSHA256After=sha((source/parent).read_bytes()),sha256=sha(wire),derivation='Only signed AdjustmentIntensity DWORD replaced; SDK SetParameters2 observation retained separately'))
(out/'endpoint-derived-wire-manifest.json').write_text(json.dumps(dict(cases=rows),indent=2)+'\n')
print('Derived eight endpoint wires; original manifests and source bytes preserved.')
