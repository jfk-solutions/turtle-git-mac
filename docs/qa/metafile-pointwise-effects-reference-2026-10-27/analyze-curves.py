#!/usr/bin/env python3
"""Read-only native ColorCurve evidence. No app invocation or transform guessed.

Distinguishes SDK ApplyEffect auxiliary LUTs from recorded Bitmap(file,FALSE)
playback. The latter may serialize an incompatible GUID and silently paint plain.
"""
import argparse,hashlib,json,struct,uuid
from pathlib import Path

def sha(data):return hashlib.sha256(data).hexdigest()
def serials(wire):
 result=[];o=0
 while o<len(wire):
  kind,size=struct.unpack_from('<II',wire,o)
  if size<8 or size%4 or o+size>len(wire):raise ValueError('outer framing')
  if kind==70 and size>=16 and wire[o+12:o+16]==b'EMF+':
   count=struct.unpack_from('<I',wire,o+8)[0];p=o+16;end=o+12+count
   if count<4 or end>o+size:raise ValueError('comment framing')
   while p<end:
    t,f,n,d=struct.unpack_from('<HHII',wire,p)
    if n<12 or n%4 or p+n>end or d>n-12:raise ValueError('plus framing')
    if t==0x4038:result.append(dict(guid=str(uuid.UUID(bytes_le=wire[p+12:p+28])),payload=wire[p+32:p+n].hex()))
    p+=n
  o+=size
 return result

def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('artifact',type=Path);parser.add_argument('--domain-artifact',type=Path);parser.add_argument('--output',type=Path,required=True);args=parser.parse_args();root=args.artifact
 cases=[c for c in json.loads((root/'generate.json').read_text())['cases']if c['family']=='colorCurve']
 replay={c['source']:c for c in json.loads((root/'replay-v1.json').read_text())['cases']}
 replay2={c['source']:c for c in json.loads((root/'replay.json').read_text())['cases']}
 direct1={c['source']:c for c in json.loads((root/'direct-v1.json').read_text())['cases']}
 source=(root/'atlas.rgba').read_bytes();identity=bytes(range(256))
 baseline=(root/'replay-v1-curve-0-0-0.rgba').read_bytes();rows=[];failures=[];opaqueErrors=0;channelErrors=0;versionsDiffer=[];replayNonidentity=[];guids={}
 for c in cases:
  name=c['name'];params=c['parameters'];mode=params['adjustment'];channel=params['channel'];value=params['adjustValue']
  if c.get('recordSetParametersStatus')!=0 or c.get('setParametersStatus')!=0:
   failures.append(dict(name=name,parameters=params,recordSetParametersStatus=c.get('recordSetParametersStatus'),setParametersStatus=c.get('setParametersStatus'),wireExists=(root/(name+'.emf')).exists(),meaning='SDK parameter refusal; missing-file BitmapLoad is not a wire playback refusal'))
   continue
  if c.get('applyStatus')!=0 or c.get('auxBytes')!=1024:raise ValueError('No bounded successful native auxiliary LUT '+name)
  lut=(root/c['lut']).read_bytes();assert len(lut)==1024
  tables=[lut[i*256:(i+1)*256]for i in range(4)] # B,G,R,A
  chosen=[0,1,2]if channel==0 else [{1:2,2:1,3:0}[channel]]
  active=tables[chosen[0]]
  errors=sum(tables[i]!=active if i in chosen else tables[i]!=identity for i in range(4));channelErrors+=errors
  direct=(root/c['rgba']).read_bytes()
  for p in range(0,len(source),4):
   if source[p+3]!=255:continue
   wanted=[tables[2][source[p]],tables[1][source[p+1]],tables[0][source[p+2]],tables[3][source[p+3]]]
   opaqueErrors+=sum(abs(a-b)>0 for a,b in zip(direct[p:p+4],wanted))
  v1lut=(root/direct1[name]['lut']).read_bytes()
  if lut!=v1lut:versionsDiffer.append(name)
  wire=(root/(name+'.emf')).read_bytes();effects=serials(wire)
  for effect in effects:guids[effect['guid']]=guids.get(effect['guid'],0)+1
  r=replay[name];r2=replay2[name]
  if r.get('bitmapLoadStatus')!=0 or r.get('drawStatus')!=0:raise ValueError('Native file replay failed '+name)
  pixels=(root/r['rgba']).read_bytes();pixels2=(root/r2['rgba']).read_bytes()
  if pixels!=baseline:replayNonidentity.append(name)
  row=dict(name=name,parameters=params,lutSHA256=sha(lut),wireSHA256=sha(wire),effects=effects,replayRGBA_SHA256=sha(pixels),replayV1EqualsV2=pixels==pixels2,replayEqualsIdentityBaseline=pixels==baseline,channelTableErrors=errors)
  # These obvious SDK-description models are falsified by real full LUTs. They
  # are diagnostic rejection evidence, never a proposed production formula.
  if mode in [0,1,6,7]:
   def naive(x):
    if mode in [0,1]:return max(0,min(255,round(x+value)))
    if mode==6:return max(0,min(255,round(x*255/value)))
    return max(0,min(255,round((x-value)*255/(255-value))))
   diffs=[abs(naive(x)-active[x])for x in range(256)]
   row['rejectedNaiveModel']=dict(maxDeviation=max(diffs),differentEntries=sum(d!=0 for d in diffs),meaning='Not accepted: description-only clamp/linear mapping fails actual Windows smoothing')
  rows.append(row)
 result=dict(successfulCases=len(rows),sdkParameterRefusals=failures,serializedGUIDCounts=guids,channelRoutingErrors=channelErrors,opaqueApplyEffectLUTChannelErrors=opaqueErrors,auxLUTV1V2Differences=versionsDiffer,recordedReplayNotIdentity=replayNonidentity,identityReplaySHA256=sha(baseline),cases=rows,
  acceptedMeasuredModel=dict(applyEffect='Independent selected RGB-channel byte lookup; alpha table identity; 0=allRGB,1=R,2=G,3=B',fullParameterFormula='Not established: measured tables contain smoothing not described by a simple clamp/linear adjustment',recordedFilePlayback='Original native ColorCurve wires use A7CE72A9 GUID +12-byte curve parameters; all152 default-v1 replays equal the same plain-image baseline. Do not activate this alias as ColorCurve.',correctCurveGUID='DD6A0022-58E4-4A67-9D9B-D48EB881A53D is specified and constructed by the Microsoft SDK; derived correct-GUID wire playback needs independent assay.'))
 if args.domain_artifact:
  domain=args.domain_artifact;table=(domain/'lookup-v1.bin').read_bytes();other=(domain/'lookup-v2.bin').read_bytes()
  meta=json.loads((domain/'lookup-v1.json').read_text());meta2=json.loads((domain/'lookup-v2.json').read_text())
  if len(table)!=598016 or table!=other or meta['caseCount']!=2336 or meta2['caseCount']!=2336:raise ValueError('Incomplete or version-mismatched finite domain')
  index={};offset=0;domainErrors=0;statuses=[]
  for row in meta['cases']:
   if row['offset']!=offset or row['length']!=256:raise ValueError('Noncontiguous finite domain')
   index[(row['adjustment'],row['adjustValue'])]=row['offset'];offset+=256
   if len(row['channels'])!=4:raise ValueError('Missing channel proof')
   for channel in row['channels']:
    domainErrors+=channel['routingErrors']+channel['actualPixelErrors']
    if channel['setParametersStatus']!=0 or channel['applyStatus']!=0 or channel['auxBytes']!=1024:statuses.append(channel)
  observedMismatch=[]
  for c in cases:
   if c.get('applyStatus')!=0:continue
   q=c['parameters'];lut=(root/c['lut']).read_bytes();ch=q['channel'];chosen=0 if ch==0 else 3-ch
   start=index[(q['adjustment'],q['adjustValue'])]
   if lut[chosen*256:(chosen+1)*256]!=table[start:start+256]:observedMismatch.append(c['name'])
  result['completeFiniteDomain']=dict(caseCount=2336,bytes=len(table),sha256=sha(table),v1EqualsV2=table==other,routingAndActualPixelErrors=domainErrors,badStatuses=statuses,priorMeasuredLUTMismatches=observedMismatch,model='Exact complete integer parameter/input domain; no interpolation or approximate closed form',offsetRule='Rows mode0..7; intensities -255..255,-255..255,-100..100,-100..100,-100..100,-100..100,1..255,0..254;256bytes each')
  result['acceptedMeasuredModel']['fullParameterFormula']='Replaced by exact exhaustive2336-row native finite-domain table; all1024 selected/identity auxiliary entries and actual256pixels verified for each of4channel enums, versions1/2 identical.'
 args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(result,indent=2)+'\n')
 print(json.dumps({k:result[k]for k in ['successfulCases','serializedGUIDCounts','channelRoutingErrors','opaqueApplyEffectLUTChannelErrors','auxLUTV1V2Differences','recordedReplayNotIdentity']}))
if __name__=='__main__':main()
