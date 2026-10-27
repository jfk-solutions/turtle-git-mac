#!/usr/bin/env python3
"""Preserve original Windows wires; derive explicit BC and invalid-profile records."""
import hashlib,json,struct,sys,zlib
from pathlib import Path
src=Path(sys.argv[1]);out=Path(sys.argv[2]);out.mkdir(parents=True,exist_ok=True)
hash=lambda b:hashlib.sha256(b).hexdigest()
u32=lambda b,o:struct.unpack_from('<I',b,o)[0]
def records(b):
 p=0;result=[]
 while p<len(b):
  n=u32(b,p+4);assert n>=8 and n%4==0 and p+n<=len(b);result.append(b[p:p+n]);p+=n
 return result
def plus(b):
 return [r[16:] for r in records(b) if u32(r,0)==70 and r[12:16]==b'EMF+']
def rebuild(seed,rs):
 source=records(seed);comments=[]
 for r in rs:
  body=b'EMF+'+r;comments.append(struct.pack('<III',70,len(body)+12,len(body))+body)
 result=[];done=False
 for r in source:
  if u32(r,0)==70 and r[12:16]==b'EMF+':
   if not done:result+=comments;done=True
  else:result.append(r)
 h=bytearray(result[0]);struct.pack_into('<II',h,48,sum(map(len,result)),len(result));result[0]=bytes(h)
 return b''.join(result)
def serial(guid,payload):return struct.pack('<HHII',0x4038,0,len(payload)+32,len(payload)+20)+bytes.fromhex(guid)+struct.pack('<I',len(payload))+payload
cases=[];refusals=[]
def emit(name,wire,expected=None,origin='derived'):
 (out/name).write_bytes(wire)
 item=dict(file=name,sourceSHA256=hash(wire),origin=origin,width=256,height=64,samples=[])
 if expected is not None:
  # Exact captured source rows; avoid resampling boundary, compare premultiplied bytes.
  for y in range(4):
   for x in [8,16,32,64,96,127,128,160,192,224,248]:
    k=(y*256+x)*4;item['samples'].append(dict(x=x,y=y,rgba=list(expected[k:k+4]),tolerance=3))
 cases.append(item)
for name in ['state-seed','state-first-effect-persists','state-two-effects-save-restore','state-all-native-serials-E','state-effect-nonE-ignored','state-E-without-effect','pending-effect-across-plain-draw','pending-effect-save-restore-before-E','pending-effect-container-before-E']:
 wire=(src/(name+'.emf')).read_bytes();raw=(src/('replay-v1-'+name+'.rgba')).read_bytes();emit(name+'.emf',wire,origin='native Windows original or exact recorded-state variant')
 item=cases[-1];item['windowsRGBA']={'file':'replay-v1-'+name+'.rgba','sha256':hash(raw)}
 for y in [0,1,2,4,5,6,8,9,10,16,17,18,24,25,26,32,33,34,40,41,42,48,49,50,56,57,58,63]:
  for x in [8,32,64,96,127,160,192,224,248]:
   k=(y*256+x)*4
   covered=(any(start<=y<start+4 for start in [0,8,16,24,32,40,48]) or (56<=y<60 and 64<=x<160) or (name=='pending-effect-across-plain-draw' and 4<=y<8))
   # Existing renderer's initial white DC is distinct from SourceCopy pixels.
   # Never rewrite a covered transparent pixel (notably LUT alpha255->0).
   observed=list(raw[k:k+4]);expected=observed if covered else [255,255,255,255]
   item['samples'].append(dict(x=x,y=y,rgba=expected,tolerance=3,windowsRGBA=observed,paintCoverage=covered))
seed=(src/'state-first-effect-persists.emf').read_bytes();rs=plus(seed);effectIndex=next(i for i,r in enumerate(rs) if struct.unpack_from('<H',r)[0]==0x4038)
guid='e1dba1d3c48e174c9f4cea97ad1c343d'
for b,c in [(0,0),(30,25),(-30,-25),(255,100),(-255,-100),(1,-1)]:
 changed=rs.copy();changed[effectIndex]=serial(guid,struct.pack('<ii',b,c));emit(f'brightness-{b}-{c}.emf',rebuild(seed,changed),(src/f'bc-b{b}-c{c}.rgba').read_bytes(),'derived BC wire; native direct 256-ramp oracle')
base=rs[effectIndex]
# Exact literal asymmetric top/bottom source pattern, in both named-sRGB PNG depths.
# The 16-bit version forces ImageIO's conversion fallback; both have identical samples.
def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
pattern=bytearray()
colors=[(255,0,0,255),(0,255,0,255),(0,0,255,255),(255,255,0,255)]
for y in range(4):
 for x in range(256):pattern.extend(colors[(y+(1 if x>=128 else 0))%4])
for depth in [8,16]:
 rows=b''
 for y in range(4):
  row=bytes(pattern[y*1024:(y+1)*1024]);rows+=b'\0'+(row if depth==8 else b''.join(bytes([v,v])for v in row))
 png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',256,4,depth,6,0,0,0))+chunk(b'sRGB',b'\0')+chunk(b'IDAT',zlib.compress(rows))+chunk(b'IEND',b'')
 changed=rs.copy();index=next(i for i,r in enumerate(changed)if struct.unpack_from('<H',r)[0]==0x4008)
 old=changed[index];payload=old[12:40]+png;size=(len(payload)+15)&~3
 changed[index]=struct.pack('<HHII',0x4008,struct.unpack_from('<H',old,2)[0],size,len(payload))+payload+bytes(size-12-len(payload))
 identity=[1.0 if i//5==i%5 else 0.0 for i in range(25)]
 changed[effectIndex]=serial('15268f713379e340a5115f68fe14dd74',struct.pack('<25f',*identity))
 emit(f'fallback-srgb-{depth}bit.emf',rebuild(seed,changed),pattern,'literal independent asymmetric named-sRGB PNG; identity matrix')
invalid={
 'matrix-nan':serial(base[12:28].hex(),struct.pack('<I',0x7fc00000)+base[36:]),
 'matrix-infinite':serial(base[12:28].hex(),struct.pack('<I',0x7f800000)+base[36:]),
 'matrix-short':serial(base[12:28].hex(),base[32:-4]),
 'unknown-guid':serial('00000000000000000000000000000000',base[32:]),
 'brightness-outside':serial(guid,struct.pack('<ii',256,0)),
 'contrast-outside':serial(guid,struct.pack('<ii',0,101)),
 'brightness-short':serial(guid,struct.pack('<i',0)),
 'lut-short':serial('a972cea77f0fd740b3ccd0c02d5c3212',bytes(1020)),
}
for name,r in invalid.items():
 changed=rs.copy();changed[effectIndex]=r;wire=rebuild(seed,changed);file='refused-'+name+'.emf';(out/file).write_bytes(wire);refusals.append(dict(file=file,sourceSHA256=hash(wire)))
# Reject invalid late effect even after actual earlier paint; do not expose partial SVG.
for name,changed in [('late-invalid-after-paint',rs[:effectIndex+2]+[invalid['matrix-nan']]+rs[effectIndex+2:]),('buffer-count-mismatch',rs.copy())]:
 if name=='buffer-count-mismatch':
  bad=bytearray(base);struct.pack_into('<I',bad,28,104);changed[effectIndex]=bytes(bad)
 wire=rebuild(seed,changed);file='refused-'+name+'.emf';(out/file).write_bytes(wire);refusals.append(dict(file=file,sourceSHA256=hash(wire)))
manifest=dict(windowsRun=40491928071,artifact=12728783501,archiveSHA256='1a3147347a5d3b7df6ff90ac93be710e3253aa894f93d4e9fd20a3a1f1c943d0',startupVersion=1,originalRun=40491004875,cases=cases,refusals=refusals)
(out/'windows-reference.json').write_text(json.dumps(manifest,indent=2)+'\n')
