import pathlib,json,math,sys
P=pathlib.Path(sys.argv[1]) if len(sys.argv)>1 else pathlib.Path('build/qa/metafile-image-effects-followup-windows-2026-10-27')
source=[(x,x,x,255)for x in range(256)]+[(x,255-x,x*37&255,255)for x in range(256)]+[(70,140,210,x)for x in range(256)]+[(x,255-x,100,0)for x in range(256)]
def n(c,a,fixed):
 if not a:return 0
 c=(c*a+127)//255
 return c*((255<<16)//a)>>16 if fixed else c*255//a
def convert(p,fixed):
 *rgb,a=p;return [n(c,a,fixed)for c in rgb]+[a]
def effect(p,kind):
 r,g,b,a=p
 if kind=='matrix':return [math.floor(g*.5+31.875+.5),b,r,math.floor(a*.75+.5)]
 return [(r+63)&255,g//2,255-b,255-a]
actual=(P/'replay-state-seed.rgba').read_bytes();results=[]
for kind,y in [('matrix',0),('lut',16)]:
 for fixed in [False,True]:
  predicted=[]
  for p in source:
   v=effect(convert(p,fixed),kind)
   # Actual Bitmap(file) rasterization, then natural DrawImage capture.
   v=convert(convert(v,fixed),fixed)
   predicted.extend(v)
  observed=actual[y*256*4:(y+4)*256*4];errors=[abs(a-b)for a,b in zip(observed,predicted)]
  results.append(dict(effect=kind,sourceNormalization='fixed16.16'if fixed else'integerExact',maxError=max(errors),differentBytes=sum(e!=0 for e in errors),pixels=1024))
print(json.dumps(results,indent=2))
path=pathlib.Path(__file__).resolve().parent/'prior-normalization-analysis.json';path.write_text(json.dumps({'scope':'Analytic source model against original native captured state-seed first matrix and LUT bands; no app/renderer execution. Includes measured half-up matrix formula; source normalization and both output associations are explicit.','results':results},indent=2)+'\n')
