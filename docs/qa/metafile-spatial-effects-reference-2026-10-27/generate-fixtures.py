#!/usr/bin/env python3
"""Retain native spatial-effect EMFs/full Picture RGBA and derive wire refusals.

No numerical effect is implemented. Source files and pixels remain independent
Windows observations; malformed profiles change only the serialized parameters.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import uuid

helper_path=Path(__file__).parent.parent/'metafile-pointwise-effects-reference-2026-10-27/generate-fixtures.py'
spec=importlib.util.spec_from_file_location('pointwise_wire_helpers',helper_path)
wire_helpers=importlib.util.module_from_spec(spec);spec.loader.exec_module(wire_helpers)
GUIDS={
 'blur':uuid.UUID('633C80A4-1843-482B-9EF2-BE2834C5FDD4').bytes_le,
 'sharpen':uuid.UUID('63CBF3EE-C526-402C-8F71-62C540BF5142').bytes_le,
 'redEyeCorrection':uuid.UUID('74D29D05-69A4-4266-9549-3CC52836B632').bytes_le,
}
def sha(data):return hashlib.sha256(data).hexdigest()
def raw(root,item):
 data=(root/item['rgba']).read_bytes()
 if len(data)!=item['width']*item['height']*4:raise ValueError('native RGBA extent')
 return data

def append_reference(root,out,run,artifact,archive,prefix,cases,sdk_refusals,coverage):
 """Retain one independently captured corpus; never synthesize expected pixels."""
 if not prefix or any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789-' for c in prefix):raise ValueError('reference prefix')
 if len(archive)!=64 or any(c not in '0123456789abcdef'for c in archive):raise ValueError('archive identity')
 names=['generate.json','replay-v1.json','replay.json']
 manifests={name:json.loads((root/name).read_text())for name in names}
 generated=manifests['generate.json'];one=manifests['replay-v1.json'];two=manifests['replay.json']
 def entries(manifest):return manifest['cases']+([manifest['baseline']]if 'baseline'in manifest else[])
 def named(manifest,leading):
  items=entries(manifest);result={item['name'].removeprefix(leading):item for item in items}
  if len(result)!=len(items):raise ValueError('duplicate native case name')
  return result
 originals=named(generated,'');first=named(one,'replay-v1-');second=named(two,'replay-')
 if set(originals)!=set(first)or set(first)!=set(second):raise ValueError('native reference case sets disagree')
 provenance=dict(prefix=prefix,windowsRun=int(run),artifact=int(artifact),archiveSHA256=archive,startupVersion=1,sourceCaseCount=len(generated['cases']),sourceControlCount=int('baseline'in generated),manifestSHA256={n:sha((root/n).read_bytes())for n in names})
 existing={c['file']for c in cases};positive=0;refused=0
 for name,original in originals.items():
  observed=first[name];other=second[name];family=original['family'];parameters=original['parameters']
  if family not in GUIDS:raise ValueError('unexpected native family '+name)
  if original.get('error')or observed.get('error')or other.get('error'):raise ValueError('native observation error '+name)
  direct=original.get('direct',{})
  if original.get('recordSetParametersStatus')!=0:
   if family!='redEyeCorrection'or original.get('recordSetParametersStatus')!=2 or direct.get('setParametersStatus')!=2:raise ValueError('unexpected SDK refusal '+name)
   sdk_refusals.append(dict(name=prefix+'-'+name,family=family,parameters=parameters,setParametersStatus=2,referencePrefix=prefix,meaning='SDK parameter refusal; missing file load is not wire rejection proof'))
   refused+=1;continue
  if any(original.get(k)!=0 for k in ['recordCreateStatus','recordStatus']):raise ValueError('native recording failed '+name)
  for replay in [observed,other]:
   if replay.get('bitmapLoadStatus')!=0 or replay.get('drawStatus')!=0 or replay.get('expectedSize')is not True:raise ValueError('native Picture replay failed '+name)
  rgba=raw(root,observed);rgba2=raw(root,other);width,height=observed['width'],observed['height']
  if (width,height)!=(other['width'],other['height']):raise ValueError('startup versions disagree on extent '+name)
  source_file=original.get('emf',name+'.emf');wire=(root/source_file).read_bytes();records=wire_helpers.comments(wire)
  effects=[r for r in records if struct.unpack_from('<H',r)[0]==0x4038 and r[12:28]==GUIDS[family]]
  if len(effects)!=1:raise ValueError('native serialization is not expected effect '+name)
  file=prefix+'-'+name+'.emf';rawfile=prefix+'-'+name+'.windows.rgba'
  if file in existing:raise ValueError('supplemental output collision '+file)
  existing.add(file)
  points={(x,y)for x in [0,width//2,width-1]for y in [0,height//2,height-1]}
  alpha_points={}
  for i in range(0,len(rgba),4):alpha_points.setdefault(rgba[i+3],(i//4%width,i//4//width))
  points.update(list(alpha_points.values())[:8])
  samples=[dict(x=x,y=y,rgba=list(rgba[(y*width+x)*4:(y*width+x)*4+4]),tolerance=1)for x,y in sorted(points,key=lambda p:(p[1],p[0]))]
  (out/file).write_bytes(wire);(out/rawfile).write_bytes(rgba)
  # Save original recording geometry and per-stage statuses as evidence, not as
  # computed expected results. Core still compares the entire native raster.
  geometry={key:original[key]for key in ['sourceWidth','sourceHeight','recordSourceRect','recordImageMatrix','recordFrameWidth','recordFrameHeight','recordBackgroundRGBA','directROI','directROIPolicy','sourceDefinition']if key in original}
  entry=dict(file=file,family=family,parameters=parameters,width=width,height=height,sourceSHA256=sha(wire),referenceRGBA=rawfile,rgbaSHA256=sha(rgba),samples=samples,alphaTolerance=1,v1EqualsV2=rgba==rgba2,directSetParametersStatus=direct.get('setParametersStatus'),directApplyStatus=direct.get('applyStatus'),createdSetParametersStatus=original.get('created',{}).get('setParametersStatus'),createdApplyStatus=original.get('created',{}).get('applyStatus'),referencePrefix=prefix,referenceOriginalName=name,isNativeBaseline=name==generated.get('baseline',{}).get('name'),nativeGeometry=geometry,origin='Original supplemental native Windows EMF and default-v1 Bitmap(file,FALSE) full raster')
  cases.append(entry);coverage[family]+=1;positive+=1
 provenance.update(retainedCases=positive,sdkRefusals=refused,allV1EqualsV2=all(c['v1EqualsV2']for c in cases if c.get('referencePrefix')==prefix))
 return provenance

def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('artifact',type=Path);p.add_argument('output',type=Path)
 p.add_argument('--append-reference',nargs=5,action='append',default=[],metavar=('DIR','RUN','ARTIFACT','SHA256','PREFIX'),help='Append an original capture with independent provenance; repeat for each reference.')
 p.add_argument('--run-id',type=int,required=True);p.add_argument('--artifact-id',type=int,required=True);p.add_argument('--archive-sha256',required=True)
 a=p.parse_args();root=a.artifact;out=a.output;out.mkdir(parents=True,exist_ok=True)
 if len(a.archive_sha256)!=64 or any(c not in '0123456789abcdef'for c in a.archive_sha256):raise ValueError('archive identity')
 generate=json.loads((root/'generate.json').read_text());v1=json.loads((root/'replay-v1.json').read_text());v2=json.loads((root/'replay.json').read_text())
 records={c['name']:c for c in generate['cases']};second={c['name'].removeprefix('replay-'):c for c in v2['cases']}
 atlases={c['name']:c for c in generate['atlases']}
 cases=[];refusals=[];sdkRefusals=[];coverage={family:0 for family in GUIDS};seeds={}
 for observed in v1['cases']:
  name=observed['name'].removeprefix('replay-v1-');original=records[name];family=original['family'];parameters=original['parameters']
  if family not in GUIDS:raise ValueError('unexpected native family')
  if original.get('error')or observed.get('error'):raise ValueError('native observation error '+name)
  if original.get('recordSetParametersStatus')!=0:
   if family!='redEyeCorrection'or original.get('recordSetParametersStatus')!=2 or original.get('direct',{}).get('setParametersStatus')!=2:raise ValueError('unexpected SDK refusal '+name)
   sdkRefusals.append(dict(name=name,family=family,parameters=parameters,setParametersStatus=2,meaning='SDK parameter refusal; missing file load is not wire rejection proof'))
   continue
  if any(original.get(k)!=0 for k in ['recordCreateStatus','recordStatus']):raise ValueError('native recording failed '+name)
  if observed.get('bitmapLoadStatus')!=0 or observed.get('drawStatus')!=0 or observed.get('expectedSize')is not True:raise ValueError('native Picture replay failed '+name)
  two=second[name]
  if two.get('error')or two.get('bitmapLoadStatus')!=0 or two.get('drawStatus')!=0 or two.get('expectedSize')is not True:raise ValueError('native v2 replay failed '+name)
  rgba=raw(root,observed);rgba2=raw(root,two);width,height=observed['width'],observed['height']
  if (width,height)!=(two['width'],two['height']):raise ValueError('startup versions disagree on extent '+name)
  file=name+'.emf';wire=(root/file).read_bytes();rs=wire_helpers.comments(wire)
  effects=[(i,r)for i,r in enumerate(rs)if struct.unpack_from('<H',r)[0]==0x4038 and r[12:28]==GUIDS[family]]
  if len(effects)!=1:raise ValueError('native serialization is not expected effect '+name)
  seeds.setdefault(family,(wire,rs,effects[0][0],name))
  # Bounded native samples; every pixel remains in the separate Core RGBA oracle.
  points={(x,y)for x in [0,width//2,width-1]for y in [0,height//2,height-1]}
  if width>=32 and height>=32:
   points|={(x,y)for x,y in [(1,1),(15,15),(16,16),(30,30),(0,16),(31,16),(16,0),(16,31)]}
  alpha_points={}
  for i in range(0,len(rgba),4):alpha_points.setdefault(rgba[i+3],(i//4%width,i//4//width))
  points.update(list(alpha_points.values())[:8])
  direct=original.get('direct',{});directChanged=None
  if direct.get('setParametersStatus')==0 and direct.get('applyStatus')==0:
   source=raw(root,atlases[original['atlas']]);actual=raw(root,direct)
   if len(source)==len(actual):
    changes=[i for i in range(0,len(source),4)if source[i+3]==255 and actual[i+3]==255 and source[i:i+3]!=actual[i:i+3]]
    directChanged=len(changes)
    points.update((i//4%width,i//4//width)for i in changes[:4]if i//4//width<height)
  samples=[dict(x=x,y=y,rgba=list(rgba[(y*width+x)*4:(y*width+x)*4+4]),tolerance=1)for x,y in sorted(points,key=lambda p:(p[1],p[0]))]
  rawfile=name+'.windows.rgba';(out/file).write_bytes(wire);(out/rawfile).write_bytes(rgba)
  cases.append(dict(file=file,family=family,parameters=parameters,width=width,height=height,sourceSHA256=sha(wire),referenceRGBA=rawfile,rgbaSHA256=sha(rgba),samples=samples,alphaTolerance=1,v1EqualsV2=rgba==rgba2,directOpaqueChangedPixelCount=directChanged,directSetParametersStatus=direct.get('setParametersStatus'),directApplyStatus=direct.get('applyStatus'),origin='Original native Windows EMF and default-v1 Bitmap(file,FALSE) full raster'))
  coverage[family]+=1
 if set(seeds)!=set(GUIDS):raise ValueError('missing positive family')
 def refuse(family,suffix,payload,declared=None,late=False,empty_crop=False):
  wire,records,index,name=seeds[family];replacement=wire_helpers.serial(GUIDS[family],payload,declared=declared);changed=records.copy()
  if late:
   draw=next(i for i,r in enumerate(records)if struct.unpack_from('<H',r)[0]in(0x401a,0x401b));changed.insert(draw+1,replacement)
  else:changed[index]=replacement
  if empty_crop:
   draw=next(i for i,r in enumerate(changed)if struct.unpack_from('<H',r)[0]==0x401b)
   record=bytearray(changed[draw])
   if len(record)<40 or struct.unpack_from('<I',record,16)[0]!=2:raise ValueError('unexpected native DrawImagePoints source profile')
   struct.pack_into('<ffff',record,20,64.,64.,8.,8.);changed[draw]=bytes(record)
  result=wire_helpers.rebuild(wire,changed);file='refused-'+family+'-'+suffix+'.emf';(out/file).write_bytes(result)
  entry=dict(file=file,family=family,sourceSHA256=sha(result),derivedFrom=name+'.emf')
  if empty_crop:entry['derivedSourceRect']=[64,64,8,8]
  refusals.append(entry)
 for family,(wire,records,index,name)in seeds.items():
  payload=records[index][32:]
  refuse(family,'short',payload[:-4]);refuse(family,'trailing',payload+bytes(4));refuse(family,'declared-mismatch',payload,declared=len(payload)+4);refuse(family,'late-invalid-after-paint',payload[:-4],late=True)
  if family in ('blur','sharpen'):
   for label,value in [('negative',-1.),('nan',float('nan')),('infinity',float('inf')),('above',256.)]:
    refuse(family,'radius-'+label,struct.pack('<f',value)+payload[4:])
   if family=='blur':refuse(family,'expand-not-bool',payload[:4]+struct.pack('<I',2))
   else:
    for label,value in [('negative',-1.),('nan',float('nan')),('infinity',float('inf')),('above',101.)]:refuse(family,'amount-'+label,payload[:4]+struct.pack('<f',value))
  else:
   for label,value in [('negative',-1),('overflow',2147483647),('over-budget',4097)]:refuse(family,'count-'+label,struct.pack('<i',value)+payload[4:])
   refuse(family,'count-extent',struct.pack('<i',1)+bytes(32))
   # Valid wholly outside first area cannot conceal a malformed later area.
   # Empty source geometry is an independent shortcut and must not bypass the
   # exact same wire validation; preserve all original records except the
   # serialized block and, for that variant, the first floating source rect.
   outside=struct.pack('<iiii',40,40,50,50)
   malformed=[('count-zero',struct.pack('<i',0)),
              ('outside-then-reversed-area',struct.pack('<i',2)+outside+struct.pack('<iiii',4,4,3,8)),
              ('outside-then-zero-extent-area',struct.pack('<i',2)+outside+struct.pack('<iiii',4,4,4,8))]
   for suffix,bad in malformed:
    refuse(family,suffix,bad)
    refuse(family,'empty-crop-'+suffix,bad,empty_crop=True)
 baseCaseCount=len(cases);references=[];seen_prefixes=set()
 for directory,run,artifact,archive,prefix in a.append_reference:
  if prefix in seen_prefixes:raise ValueError('duplicate reference prefix')
  seen_prefixes.add(prefix)
  references.append(append_reference(Path(directory),out,run,artifact,archive,prefix,cases,sdkRefusals,coverage))
 manifest=dict(windowsRun=a.run_id,artifact=a.artifact_id,startupVersion=1,archiveSHA256=a.archive_sha256,sourceCaseCount=len(generate['cases']),baseRetainedCaseCount=baseCaseCount,supplementalReferences=references,coverage=coverage,cases=cases,refusals=refusals,sdkRefusals=sdkRefusals,qualification='Original file-consumer pixels retained. Direct SDK statuses and source pixels are separate evidence; no generated numerical oracle or unmeasured tolerance.')
 (out/'windows-reference.json').write_text(json.dumps(manifest,indent=2)+'\n')
 (out/'README.md').write_text('# Native Windows spatial image effects\n\nOriginal EMF bytes and full default-v1 Bitmap(file,FALSE) straight-RGBA observations. The Core comparison covers every pixel. Bounded native samples do not replace full raster evidence. SDK parameter refusals are recorded separately from derived malformed-wire refusals. Supplemental captures use stable prefixes and separate run/artifact/archive/manifest provenance. Their native geometry and all full rasters remain unmodified; every family keeps a one-byte oracle.\n')
 print(json.dumps(dict(cases=len(cases),coverage=coverage,refusals=len(refusals),sdkRefusals=len(sdkRefusals))))
if __name__=='__main__':main()
