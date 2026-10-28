#!/usr/bin/env python3
"""Add independent first-use/ROI reference contexts without rewriting old oracles."""
from pathlib import Path
import argparse,json,hashlib,copy
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--capture',type=Path,required=True)
parser.add_argument('--corpus',type=Path,required=True)
args=parser.parse_args();source=args.capture;folder=args.corpus

def write_new_or_identical(name,data):
 assert name==Path(name).name and name not in ('','.', '..')
 target=folder/name
 if target.exists():assert target.read_bytes()==data,'Refusing to overwrite reference '+name
 else:target.write_bytes(data)

sha=lambda data:hashlib.sha256(data).hexdigest()
original=json.loads((folder/'windows-reference.json').read_text());by_name={x['file']:x for x in original['cases']}
replacements=[];additional=[];history=[]
def observed(label):return json.loads((source/(label+'.json')).read_text(encoding='utf-8-sig'))
def samples(data,w,h):
 return [{'x':x,'y':y,'rgba':list(data[(y*w+x)*4:(y*w+x)*4+4]),'tolerance':1} for y in sorted({0,h//4,h//2,3*h//4,h-1}) for x in sorted({0,w//4,w//2,3*w//4,w-1})]
for index,name in enumerate(['followup-solid-pure-red.emf','detector-color-pure-red.emf']):
 old=by_name[name];fresh=observed(f'fresh-{index}-1')['cases'][0]['final'];data=(source/fresh['rgba']).read_bytes()
 repeats=[]
 for repeat in range(1,4):
  case=observed(f'fresh-{index}-{repeat}')['cases'][0]
  for stage in ['intrinsic','final']:assert (source/case[stage]['rgba']).read_bytes()==data
  repeats.append({'label':f'fresh-{index}-{repeat}','finalSHA256':sha(data),'intrinsicSHA256':sha(data)})
 assert sha((source/name).read_bytes())==old['sourceSHA256']
 assert sha(data)!=old['rgbaSHA256']
 target='fresh-file-v1-'+Path(name).stem+'.rgba';write_new_or_identical(target,data)
 current=copy.deepcopy(old);current.update(referenceRGBA=target,rgbaSHA256=sha(data),samples=samples(data,fresh['width'],fresh['height']))
 replacements.append({'file':name,'sourceSHA256':old['sourceSHA256'],'previousReferenceRGBA':old['referenceRGBA'],'previousRGBA_SHA256':old['rgbaSHA256'],'freshRepeats':repeats,'case':current})
 contexts=[]
 for label in ['sequence-forward','sequence-reverse']:
  case=next(c for c in observed(label)['cases'] if c['file']==name)
  contexts.append({'label':label,'order':case['order'],'finalSHA256':sha((source/case['final']['rgba']).read_bytes()),'intrinsicSHA256':sha((source/case['intrinsic']['rgba']).read_bytes())})
 assert any(c['finalSHA256']==old['rgbaSHA256'] for c in contexts)
 history.append({'file':name,'freshFirstUseSHA256':sha(data),'priorCapturedSHA256':old['rgbaSHA256'],'contexts':contexts})
recording=json.loads((source/'generate-blur-roi.json').read_text(encoding='utf-8-sig'))
for item in recording['cases']:
 name=item['emf'];label='blur-'+item['name'].removeprefix('blur-roi-');case=observed(label)['cases'][0];result=case['final'];data=(source/result['rgba']).read_bytes()
 target='picture-file-v1-'+Path(name).stem+'.rgba'
 write_new_or_identical(name,(source/name).read_bytes());write_new_or_identical(target,data)
 additional.append({'file':name,'family':'blur','sourceSHA256':sha((source/name).read_bytes()),'referenceRGBA':target,'rgbaSHA256':sha(data),'width':64,'height':64,'alphaTolerance':1,'samples':samples(data,64,64),'parameters':item['parameters'],'recordSourceRect':item['recordSourceRect'],'recordStatus':item['recordStatus'],'referenceContext':label,'intrinsicSHA256':sha((source/case['intrinsic']['rgba']).read_bytes())})
value={'windowsRun':40683242082,'artifact':12812964186,'archiveSHA256':'2745d7bd0b82a74f456d185586124ae94dd6c7a6969fde9405a1b14d4d854108','sourceCommit':'4438157375b49d8758f8ec8dcc48c3a130c17ee1','startupVersion':1,'consumer':'fresh process: Bitmap(file,FALSE), immediate Picture SourceCopy/default interpolation/half pixel offset/TileFlipXY, then observation','originalManifestSHA256':sha((folder/'windows-reference.json').read_bytes()),'replacements':replacements,'historyObservations':history,'additionalCases':additional,'limitations':'Old references remain unchanged and valid for their captured process histories. Fresh-first-use context is the independent per-conversion target; no claim that a particular prior effect causes the changed history values.'}
write_new_or_identical('playback-context-reference.json',(json.dumps(value,indent=2)+'\n').encode())
print('Added independent fresh-process context references: 2 preserved-wire comparisons and 5 new bounded ROI cases; original627 manifest unchanged')
