#!/usr/bin/env python3
"""Assay normative ColorCurve GUID and SDK-refused endpoints without direct regeneration.

Preserve all152 original native A7CE72A9/12-byte wires as original-<stem>.emf;
then derive all160 normative DD6A0022 wires under the existing C++ replay stems.
Original generate/direct/replay manifests remain unchanged. An absent endpoint
file's old BitmapLoad2 is never called a wire playback refusal.
"""
import hashlib,json,struct,sys,uuid
from pathlib import Path
source=Path(sys.argv[1]);out=Path(sys.argv[2])if len(sys.argv)>2 else source
out.mkdir(parents=True,exist_ok=True)
observed=uuid.UUID('A7CE72A9-0F7F-40D7-B3CC-D0C02D5C3212').bytes_le
normative=uuid.UUID('DD6A0022-58E4-4A67-9D9B-D48EB881A53D').bytes_le
sha=lambda b:hashlib.sha256(b).hexdigest()
cases=[c for c in json.loads((source/'generate.json').read_text())['cases']if c['family']=='colorCurve']
if len(cases)!=160:raise ValueError('Expected160 source curve parameter observations')
originals={};backups=[]
# Snapshot every original before modifying any standard stem: endpoint sources
# must not depend on mutation order. A repeated invocation reuses exact backups.
for case in cases:
 if case.get('recordSetParametersStatus')!=0:continue
 name=case['name']+'.emf';backup='original-'+name
 original=(source/backup).read_bytes()if(source/backup).exists()else(source/name).read_bytes()
 target=out/backup
 if target.exists()and target.read_bytes()!=original:raise ValueError('Conflicting original backup '+backup)
 target.write_bytes(original);originals[case['name']]=original
 backups.append(dict(file=backup,originalFile=name,sha256=sha(original)))
if len(originals)!=152:raise ValueError('Expected152 preserved original SDK-accepted wires')
rows=[]
for case in cases:
 params=case['parameters'];mode,channel,value=params['adjustment'],params['channel'],params['adjustValue'];name=case['name']+'.emf'
 parent=case['name'];originalValue=value
 if parent not in originals:
  if mode==6 and value==0:originalValue=1
  elif mode==7 and value==255:originalValue=254
  else:raise ValueError('Unexpected SDK-refused profile '+parent)
  parent=f'curve-{mode}-{channel}-{originalValue}'
 original=originals[parent];wire=bytearray(original);offset=0;changed=0
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
    if t==0x4038 and wire[p+12:p+28]==observed:
     if n!=44 or data!=32 or struct.unpack_from('<I',wire,p+28)[0]!=12:raise ValueError('curve size')
     if struct.unpack_from('<IIi',wire,p+32)!=(mode,channel,originalValue):raise ValueError('unexpected source parameters')
     wire[p+12:p+28]=normative;struct.pack_into('<i',wire,p+40,value);changed+=1
    p+=n
  offset+=size
 if changed!=1:raise ValueError(f'Expected exactly one observed nativeA7CE12 effect, found{changed}: {parent}')
 wire=bytes(wire);target=out/name
 if target.exists()and target.read_bytes()not in(original,wire):raise ValueError('Refusing to overwrite a different wire '+name)
 target.write_bytes(wire)
 rows.append(dict(file=name,source='original-'+parent+'.emf',sourceSHA256=sha(original),sourceParameters=dict(adjustment=mode,channel=channel,adjustValue=originalValue),parameters=params,sha256=sha(wire),changedGUID=True,changedIntensity=value!=originalValue,observedGUID=str(uuid.UUID(bytes_le=observed)),derivedGUID=str(uuid.UUID(bytes_le=normative)),derivation='Only serialized GUID and (for8SDK-refused endpoints) signed AdjustmentIntensity DWORD replaced; original native wire and SDK refusal reports retained'))
manifest=dict(preservedOriginals=backups,cases=rows,originalCount=len(backups),derivedCount=len(rows))
(out/'endpoint-derived-wire-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Preserved152 original native wires; derived160 normative-GUID curve wires; original reports untouched.')
