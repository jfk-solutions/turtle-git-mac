#!/usr/bin/env python3
"""Analyze captured native Windows outputs only; no app/renderer execution."""
import json, math, pathlib, hashlib, sys
ROOT=pathlib.Path(__file__).resolve().parent
P=pathlib.Path(sys.argv[1]) if len(sys.argv)>1 else pathlib.Path('build/qa/metafile-pointwise-effects-native-windows-2026-10-27')
def byte(v): return max(0,min(255,math.floor(v+.5)))
def table(family,p):
 if family=='colorBalance': return [[min(255,(x*(100+p[k])+50)//100) for x in range(256)] for k in ['cyanRed','magentaGreen','yellowBlue']]
 h,m,s=[p[k] for k in ['highlight','midtone','shadow']];gamma=10**(-m/100)
 def f(x):
  if h==s==0:return 255
  if h<s:return byte(255*(1-max(0,min(1,(x-255*h/100)/(255*(s-h)/100)))**gamma))
  return byte(255*max(0,min(1,(x-255*s/100)/max(1,255*(h-s)/100)))**gamma)
 t=[f(x) for x in range(256)];return [t,t,t]
def normalize(c,a):return 0 if not a else min(255,(((c*a+127)//255)*((255<<16)//a))>>16)
def errors(a,b):
 e=[abs(x-y)for x,y in zip(a,b)];return {'maxError':max(e,default=0),'differentBytes':sum(x!=0 for x in e),'bytes':len(e)}
manifest=json.load(open(P/'generate.json'));src=(P/'atlas.rgba').read_bytes();reports=[]
for c in manifest['cases']:
 if c['family'] not in ['colorBalance','levels']:continue
 t=table(c['family'],c['parameters']);actual=(P/c['rgba']).read_bytes();pred=bytes(t[k][src[i+k]]if k<3 else src[i+k]for i in range(0,len(src),4)for k in range(4))
 aux=(P/c['lut']).read_bytes();expectedAux=bytes(t[2]+t[1]+t[0]+list(range(256)))
 draw=bytes(normalize(t[k][normalize(src[i+k],src[i+3])],src[i+3]) if k<3 else src[i+3]for i in range(0,len(src),4)for k in range(4))
 replay=(P/('replay-'+c['name']+'.rgba')).read_bytes();intrinsic=(P/('replay-'+c['name']+'-intrinsic.rgba')).read_bytes()
 reports.append({'name':c['name'],'parameters':c['parameters'],'direct':errors(actual,pred),'directV1':errors((P/('direct-v1-'+c['name']+'.rgba')).read_bytes(),pred),'auxBGRA':errors(aux,expectedAux),'auxBGRAV1':errors((P/('direct-v1-'+c['name']+'.lut')).read_bytes(),expectedAux),'drawOpaque':errors(replay[:985*4],draw[:985*4]),'drawAll':errors(replay,draw),'drawAfterSecondAssociation':errors(replay,bytes(normalize(draw[i+k],draw[i+3])if k<3 else draw[i+3] for i in range(0,len(draw),4)for k in range(4))),'intrinsicAll':errors(intrinsic,draw),'intrinsicV1':errors((P/('replay-v1-'+c['name']+'-intrinsic.rgba')).read_bytes(),draw),'drawV1MatchesV2':errors((P/('replay-v1-'+c['name']+'.rgba')).read_bytes(),replay),'inputSHA256':hashlib.sha256((P/c['emf']).read_bytes()).hexdigest()})
out={'scope':'Windows captured pointwise ColorBalance and Levels analysis; no renderer tests','models':{'balance':'per-channel clamp((input*(100+parameter)+50)//100), alpha unchanged','levels':'gamma=10^(-midtone/100); low=255*shadow/100, high=255*highlight/100. Forward when high>=low: clamp((input-low)/max(1,high-low))^gamma. Inverted when high<low: 1-clamp((input-high)/(low-high))^gamma. Scale255 and half-up round. Both bounds0 => all255.','draw':'GDI+ input and output normalization: associated=floor((channel*alpha+127)/255), reciprocal=floor((255*65536)/alpha), straight=floor(associated*reciprocal/65536); alpha0 RGB0. Bitmap intrinsic includes input+output association, DrawImage capture includes a second output association.'},'cases':reports,'limits':['Models established on captured parameter grid; not proof of all SDK integer combinations.','Native GDI+ versions and exact numeric intermediates are not inferred from equal outputs.']}
path=ROOT/'balance-levels-analysis.json';path.write_text(json.dumps(out,indent=2)+'\n')
for fam in ['balance-','levels-']:
 group=[r for r in reports if r['name'].startswith(fam)]
 print(fam,len(group),{k:(max(r[k]['maxError']for r in group),sum(r[k]['differentBytes']for r in group))for k in ['direct','directV1','auxBGRA','auxBGRAV1','drawOpaque','drawAll','intrinsicAll','intrinsicV1','drawV1MatchesV2','drawAfterSecondAssociation']})
print(path)
