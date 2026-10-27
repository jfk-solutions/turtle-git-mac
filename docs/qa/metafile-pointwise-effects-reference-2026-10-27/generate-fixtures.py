#!/usr/bin/env python3
"""Preserve native Windows effect wires/pixels and derive bounded wire refusals.

No color-transform formula is implemented here. Positive pixels come exclusively
from successful native Bitmap(file,FALSE) replay, never from the app renderer.
"""
import argparse
import hashlib
import json
import struct
import uuid
from pathlib import Path

# Primary wire contracts: MS-EMFPLUS 2.1.3.1, 2.2.3.3/4/7/8/11.
# https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/18f3cb09-8793-42e1-9337-b24794d4223c
# https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/9d18533b-502e-4226-bb19-5a9a1865c026
# SDK enums: https://learn.microsoft.com/en-us/windows/win32/api/gdipluseffects/ne-gdipluseffects-curveadjustments
EFFECTS={
 'colorBalance':('537E597D-251E-48DA-9664-29CA496B70F8',[(-100,100)]*3),
 'hueSaturationLightness':('8B2DD6C3-EB07-4D87-A5F0-7108E26A9C5F',[(-180,180),(-100,100),(-100,100)]),
 'levels':('99C354EC-2A31-4F3A-8C34-17A803B33A25',[(0,100),(-100,100),(0,100)]),
 'colorCurve':('DD6A0022-58E4-4A67-9D9B-D48EB881A53D',None),
 'tint':('1077AF00-2848-4441-9489-44AD4C2D7A2C',[(-180,180),(-100,100)]),
}
GUIDS={uuid.UUID(guid).bytes_le:kind for kind,(guid,_) in EFFECTS.items()}
def sha(data):return hashlib.sha256(data).hexdigest()
def u32(data,offset):return struct.unpack_from('<I',data,offset)[0]
def split(data,plus=False):
 result=[];offset=0;minimum=12 if plus else 8
 while offset<len(data):
  if len(data)-offset<minimum:raise ValueError('truncated record header')
  size=u32(data,offset+4)
  if size<minimum or size%4 or size>len(data)-offset:raise ValueError('record framing')
  record=data[offset:offset+size]
  if plus and u32(record,8)>size-12:raise ValueError('EMF+ data extent')
  result.append(record);offset+=size
 return result
def comments(wire):
 records=[]
 for outer in split(wire):
  if u32(outer,0)==70 and len(outer)>=16 and outer[12:16]==b'EMF+':
   size=u32(outer,8)
   if size<4 or size>len(outer)-12:raise ValueError('comment extent')
   records.extend(split(outer[16:12+size],plus=True))
 return records
def rebuild(seed,records):
 # Native EMF+Only recordings can still carry GDI fallback records. Retain
 # every outer record and comment position; replace only the one body comment.
 original=split(seed);bodyIndices=[];header=None;eof=None
 for i,outer in enumerate(original):
  if u32(outer,0)!=70 or outer[12:16]!=b'EMF+':continue
  count=u32(outer,8)
  if count<4 or count>len(outer)-12:raise ValueError('comment extent')
  items=split(outer[16:12+count],plus=True)
  if len(items)==1 and struct.unpack_from('<H',items[0])[0]==0x4001:
   if header is not None:raise ValueError('ambiguous EMF+ header comments')
   header=items[0]
  elif len(items)==1 and struct.unpack_from('<H',items[0])[0]==0x4002:
   if eof is not None:raise ValueError('ambiguous EMF+ EOF comments')
   eof=items[0]
  else:bodyIndices.append(i)
 if len(bodyIndices)!=1 or header is None or eof is None:raise ValueError('derived profile requires exactly one body and separate header/EOF comments')
 if len(records)<2 or records[0]!=header or records[-1]!=eof:raise ValueError('derived profile altered header/EOF')
 bodyRecords=records[1:-1]
 if any(struct.unpack_from('<H',r)[0]in(0x4001,0x4002)for r in bodyRecords):raise ValueError('embedded duplicate header/EOF')
 body=b'EMF+'+b''.join(bodyRecords);output=original.copy();output[bodyIndices[0]]=struct.pack('<III',70,len(body)+12,len(body))+body
 h=bytearray(output[0]);struct.pack_into('<II',h,48,sum(map(len,output)),len(output));output[0]=bytes(h)
 return b''.join(output)

def serial(guid,payload,declared=None,flags=0):
 if len(payload)%4:raise ValueError('unaligned effect buffer')
 return struct.pack('<HHII',0x4038,flags,len(payload)+32,len(payload)+20)+guid+struct.pack('<I',len(payload) if declared is None else declared)+payload

def main():
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('artifact',type=Path);parser.add_argument('output',type=Path)
 parser.add_argument('--original-artifact',type=Path,required=True)
 parser.add_argument('--run-id',type=int,required=True);parser.add_argument('--artifact-id',type=int,required=True);parser.add_argument('--archive-sha256',required=True)
 args=parser.parse_args();source=args.artifact;out=args.output;out.mkdir(parents=True,exist_ok=True)
 tintReportPath=Path(__file__).with_name('tint-model-2026-10-27.json');tintReportBytes=tintReportPath.read_bytes();tintReport=json.loads(tintReportBytes)
 tintObserved=tintReport['models']['luma_max']['replay-v1']['summary']['final_associated_rgba']['max_abs_delta']
 if tintObserved!=3 or len(tintReport['models']['luma_max']['replay-v1']['cases'])!=35:raise ValueError('Tint tolerance qualification does not match full35 native observations')
 tintQualification=dict(report='docs/qa/metafile-pointwise-effects-reference-2026-10-27/tint-model-2026-10-27.json',sha256=sha(tintReportBytes),model='luma_max',nativeCases=35,associatedRGBTolerance=3,alphaTolerance=1,otherFamiliesAssociatedRGBTolerance=1,remainingGap='Exact Windows Tint intermediates and quantization remain unresolved; only associated display-channel bound is qualified, not straight-RGBA equality')
 if len(args.archive_sha256)!=64 or any(c not in '0123456789abcdef' for c in args.archive_sha256):raise ValueError('invalid archive identity')
 replay=json.loads((source/'replay-v1.json').read_text());version2=json.loads((source/'replay.json').read_text())
 other={c['name'].removeprefix('replay-'):c for c in version2['cases']}
 recorded={c['name']:c for c in json.loads((source/'generate.json').read_text())['cases']}
 proofPath=source/'endpoint-derived-wire-manifest.json'
 proof={c['file']:c for c in json.loads(proofPath.read_text())['cases']}if proofPath.exists()else{}
 originals={};cases=[];refusals=[];derived=[];sdkRefusals=[];coverage={kind:0 for kind in EFFECTS};curves=set()
 for record in replay['cases']:
  name=record['name'].removeprefix('replay-v1-');file=name+'.emf'
  original=recorded.get(name)
  if original is None or original.get('recordError') or original.get('directError') or original.get('error'):raise ValueError(f'Native record/direct assay failed: {original}')
  wire=(source/file).read_bytes();records=comments(wire);derivedProof=proof.get(file)
  if derivedProof is not None and derivedProof['sha256']!=sha(wire):raise ValueError('Derived wire does not match measured proof '+file)
  badSDK=any(original.get(key)!=0 for key in ['recordSetParametersStatus','recordCreateStatus','recordStatus','setParametersStatus','applyStatus'])
  if badSDK:
   q=original.get('parameters',{})
   if not(derivedProof is not None and original.get('recordSetParametersStatus')==2 and original.get('setParametersStatus')==2 and ((q.get('adjustment')==6 and q.get('adjustValue')==0)or(q.get('adjustment')==7 and q.get('adjustValue')==255))):raise ValueError(f'Unexpected SDK failure: {original}')
   sdkRefusals.append(dict(name=name,parameters=q,recordSetParametersStatus=2,setParametersStatus=2,meaning='SDK refuses parameter, but derived normative wire Bitmap replay measured separately'))
  effects=[(i,r,GUIDS[r[12:28]]) for i,r in enumerate(records) if struct.unpack_from('<H',r)[0]==0x4038 and r[12:28] in GUIDS]
  if not effects:continue
  if record.get('error') or record.get('bitmapLoadStatus')!=0 or record.get('drawStatus')!=0 or record.get('expectedSize')is not True:raise ValueError(f'Native v1 replay failed: {record}')
  second=other.get(name)
  if second is None or second.get('error') or second.get('bitmapLoadStatus')!=0 or second.get('drawStatus')!=0 or second.get('expectedSize')is not True:raise ValueError(f'Native v2 replay failed: {name}')
  width,height=record['width'],record['height']
  if width!=32 or height!=32 or record.get('intrinsicWidth')!=width or record.get('intrinsicHeight')!=height:raise ValueError(f'Unexpected native frame: {name}')
  rgba=(source/record['rgba']).read_bytes();rgba2=(source/second['rgba']).read_bytes()
  if len(rgba)!=width*height*4 or len(rgba2)!=len(rgba):raise ValueError('native RGBA extent')
  kind=effects[0][2];coverage[kind]+=1;originals.setdefault(kind,(wire,records,effects[0][0],name))
  if kind=='colorCurve':
   payload=effects[0][1][32:];adjustment,channel,_=struct.unpack('<IIi',payload);curves.add((adjustment,channel))
  samples=[]
  for y in sorted(set(range(0,height,4))|{height-1}):
   for x in sorted(set(range(0,width,4))|{width-1}):
    index=(y*width+x)*4;samples.append(dict(x=x,y=y,rgba=list(rgba[index:index+4]),tolerance=3 if kind=='tint' else 1))
  (out/file).write_bytes(wire);raw=name+'.windows.rgba';(out/raw).write_bytes(rgba)
  cases.append(dict(file=file,family=kind,sourceSHA256=sha(wire),width=width,height=height,samples=samples,referenceRGBA=raw,rgbaSHA256=sha(rgba),v1EqualsV2=rgba==rgba2,parameters=record.get('parameters'),alphaTolerance=1,profile='normative',derivation=derivedProof,origin='derived normative GUID wire and actual default-v1 Bitmap(file,FALSE) pixels'if derivedProof else'original native Windows EMF and default-v1 Bitmap(file,FALSE) pixels'))
 # Preserve the separate original GDI+ serialization bug profile and its
 # actual original pixels, not the corrected-GUID replay or direct ApplyEffect.
 originalArtifact=args.original_artifact
 originalReplay=json.loads((originalArtifact/'replay-v1.json').read_text())['cases']
 originalGenerate={c['name']:c for c in json.loads((originalArtifact/'generate.json').read_text())['cases']}
 ignoredCount=0
 for record in originalReplay:
  name=record['name'].removeprefix('replay-v1-');native=originalGenerate[name]
  if native['family']!='colorCurve' or native.get('recordSetParametersStatus')!=0:continue
  if record.get('bitmapLoadStatus')!=0 or record.get('drawStatus')!=0 or record.get('expectedSize')is not True:raise ValueError('Original ignored-Curve replay failure '+name)
  wire=(originalArtifact/(name+'.emf')).read_bytes();rs=comments(wire)
  effects=[r for r in rs if struct.unpack_from('<H',r)[0]==0x4038]
  if len(effects)!=1 or effects[0][12:28]!=uuid.UUID('A7CE72A9-0F7F-40D7-B3CC-D0C02D5C3212').bytes_le or u32(effects[0],28)!=12:raise ValueError('Unexpected original serialization profile '+name)
  rgba=(originalArtifact/record['rgba']).read_bytes()
  if len(rgba)!=4096:raise ValueError('Original ignored-Curve raster size')
  file='original-'+name+'.emf';raw='original-'+name+'.windows.rgba';(out/file).write_bytes(wire);(out/raw).write_bytes(rgba)
  points=[]
  for y in sorted(set(range(0,32,4))|{31}):
   for x in sorted(set(range(0,32,4))|{31}):
    k=(y*32+x)*4;points.append(dict(x=x,y=y,rgba=list(rgba[k:k+4]),tolerance=1))
  cases.append(dict(file=file,family='colorCurve',alphaTolerance=1,profile='recordedIgnored',sourceSHA256=sha(wire),width=32,height=32,samples=points,referenceRGBA=raw,rgbaSHA256=sha(rgba),parameters=native['parameters'],origin='original native A7CE12 serialization; measured ordinary-image fallback, not active curve'))
  ignoredCount+=1
 if ignoredCount!=152:raise ValueError(f'Expected152 original ignored-Curve profiles, found{ignoredCount}')
 if not all(coverage.values()):raise ValueError(f'Incomplete five-effect native reference: {coverage}')
 if curves!={(a,c)for a in range(8)for c in range(4)}:raise ValueError(f'Incomplete curve modes/channels: {sorted(curves)}')
 def negative(kind,suffix,replacement,late=False):
  wire,records,index,name=originals[kind];changed=records.copy()
  if late:
   draw=next(i for i,r in enumerate(records)if struct.unpack_from('<H',r)[0]in(0x401a,0x401b));changed.insert(draw+1,replacement)
  else:changed[index]=replacement
  value=rebuild(wire,changed);file=f'refused-{kind}-{suffix}.emf';(out/file).write_bytes(value)
  refusals.append(dict(file=file,family=kind,sourceSHA256=sha(value),derivedFrom=name+'.emf'))
 for kind,(guid,ranges)in EFFECTS.items():
  wire,records,index,name=originals[kind];effect=records[index];guid=uuid.UUID(guid).bytes_le;payload=effect[32:]
  negative(kind,'short',serial(guid,payload[:-4]));negative(kind,'trailing',serial(guid,payload+bytes(4)))
  negative(kind,'declared-mismatch',serial(guid,payload,declared=len(payload)+4))
  negative(kind,'late-invalid-after-paint',serial(guid,payload[:-4]),late=True)
  # Serializable flags are reserved/ignored; retain positive native pixel oracle.
  changed=records.copy();changed[index]=serial(guid,payload,flags=0xffff);value=rebuild(wire,changed);file=f'ignored-flags-{kind}.emf';(out/file).write_bytes(value)
  derived.append(dict(file=file,sourceSHA256=sha(value),referenceFile=name+'.emf',origin='derived reserved flags, same native original pixel oracle'))
  values=list(struct.unpack('<'+'i'*(len(payload)//4),payload))
  if ranges:
   for field,(low,high)in enumerate(ranges):
    for label,v in [('below',low-1),('above',high+1)]:
     bad=values.copy();bad[field]=v;negative(kind,f'field{field}-{label}',serial(guid,struct.pack('<'+'i'*len(bad),*bad)))
  else:
   for field in [0,1]:
    for label,v in [('negative',-1),('outside',8 if field==0 else 4)]:
     bad=values.copy();bad[field]=v;negative(kind,f'enum{field}-{label}',serial(guid,struct.pack('<iii',*bad)))
   for adjustment in range(8):
    low,high=(-255,255)if adjustment<2 else(-100,100)if adjustment<6 else(0,255)
    for label,v in [('below',low-1),('above',high+1)]:negative(kind,f'mode{adjustment}-{label}',serial(guid,struct.pack('<IIi',adjustment,0,v)))
 stateManifest=json.loads((source/'states-v1.json').read_text())
 stateV2={c['source']:c for c in json.loads((source/'states-v2.json').read_text())['cases']}
 stateProof={c['file']:c for c in json.loads(proofPath.read_text())['stateWitnesses']}
 states=[]
 for record in stateManifest['cases']:
  file=record['source'];wire=(source/file).read_bytes();otherState=stateV2.get(file)
  if record.get('bitmapLoadStatus')!=0 or record.get('drawStatus')!=0 or record.get('expectedSize')is not True or record.get('error'):raise ValueError('State v1 replay failed '+file)
  if otherState is None or otherState.get('bitmapLoadStatus')!=0 or otherState.get('drawStatus')!=0 or otherState.get('error'):raise ValueError('State v2 replay failed '+file)
  if stateProof[file]['sha256']!=sha(wire):raise ValueError('State wire provenance mismatch '+file)
  rgba=(source/record['rgba']).read_bytes();rgba2=(source/otherState['rgba']).read_bytes()
  if len(rgba)!=4096 or rgba!=rgba2:raise ValueError('State raster extent/version mismatch '+file)
  name=Path(file).stem;raw=name+'.windows.rgba';(out/file).write_bytes(wire);(out/raw).write_bytes(rgba)
  samples=[]
  for y in sorted(set(range(0,32,4))|{31}):
   for x in sorted(set(range(0,32,4))|{31}):
    k=(y*32+x)*4;samples.append(dict(x=x,y=y,rgba=list(rgba[k:k+4]),tolerance=1))
  states.append(dict(file=file,family='effectState',alphaTolerance=1,profile='state',sourceSHA256=sha(wire),width=32,height=32,samples=samples,referenceRGBA=raw,rgbaSHA256=sha(rgba),v1EqualsV2=True,derivation=stateProof[file],origin='derived pending-state wire and actual native default-v1 Bitmap pixels'))
 if len(states)!=3:raise ValueError('Incomplete pending-state observations')
 manifest=dict(windowsRun=args.run_id,artifact=args.artifact_id,archiveSHA256=args.archive_sha256,startupVersion=1,tintQualification=tintQualification,coverage=coverage,normativeCount=sum(coverage.values()),recordedIgnoredCount=ignoredCount,sdkParameterRefusals=sdkRefusals,originalProvenance=dict(windowsRun=40500526988,artifact=12732476915,archiveSHA256='8619d457355e96f3c51f52f49750673442be5b2a8a5d94e7e2e68e8ea686423b'),curveModeChannels=sorted(curves),cases=cases,states=states,derived=derived,refusals=refusals)
 (out/'windows-reference.json').write_text(json.dumps(manifest,indent=2)+'\n')
 print(json.dumps(dict(positive=len(cases),states=len(states),derived=len(derived),refused=len(refusals),coverage=coverage)))
if __name__=='__main__':main()
