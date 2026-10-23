#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Original MS-EMFPLUS raw high-depth bitmap fixtures; no upstream image bytes.

Wire enum/bitmap/palette facts:
https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/47cbe48e-d13c-450b-8a23-6aa95488428e
https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/112a5e2c-6bb3-4daf-8ee3-0f3d3984410f
https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/c236db12-fc5d-4e5b-8266-0468881cd940

This generator writes only high-depth-* files. Each component is an explicit
little-endian word; 32-bit control pixels are separately authored color facts,
not calculated by the production decoder. Display conversion follows the reviewed Wine raw-playback high-byte profile.
Display-range policy is documented
alongside the tests; these fixtures do not certify Windows HDR/color management.
"""
from pathlib import Path
import struct
P=Path(__file__).parent
U=lambda *v:struct.pack('<'+'I'*len(v),*v)
I=lambda *v:struct.pack('<'+'i'*len(v),*v)
H=lambda *v:struct.pack('<'+'H'*len(v),*v)
F=lambda *v:struct.pack('<'+'f'*len(v),*v)
def pad(b):return b+b'\0'*((-len(b))%4)
def rec(t,b=b''):return U(t,8+len(pad(b)))+pad(b)
def ep(t,b=b'',flags=0):return H(t,flags)+U(12+len(pad(b)),len(b))+pad(b)
def plus(records):
 stream=ep(0x4001,U(0xdbc01002,0,96,96),1)+b''.join(records)+ep(0x4002)
 records=[rec(70,U(4+len(stream))+b'EMF+'+stream),rec(14,U(0,0,20))]
 return U(1,88)+I(0,0,64,64)+I(0,0,1693,1693)+U(0x464d4520,0x10000,88+sum(map(len,records)),len(records)+1)+H(16,0)+U(0,0,0)+I(960,960,254,254)+b''.join(records)
def bitmap(fmt,rows,stride,width=2,height=2,extra=b''):
 return U(0xdbc01002,1)+I(width,height,stride)+U(fmt,0)+extra+b''.join(rows if stride>0 else reversed(rows))
def scene(image,consumer='direct',prefix=False):
 records=[ep(0x400A,U(0xffffffff,1)+F(0,0,64,64),0x8000)]
 if prefix:records += [ep(0x400A,U(0xffff0000,1)+F(0,0,64,64),0x8000)]
 if consumer=='texture':
  texture=U(0xdbc01002,2,2,4)+F(24,0,0,24,8,8)+image
  records += [ep(0x4008,texture,0x100),ep(0x400A,U(0,1)+F(8,8,48,48))]
 else:
  records += [ep(0x4008,image,0x500)]
  if consumer=='mapped':
   records += [ep(0x4025,U(19)),ep(0x402D,F(4,0)),ep(0x401B,U(0xffffffff,2)+F(0,0,2,2)+U(3)+F(4,8,52,8,4,56)),ep(0x4026,U(19))]
  else:records += [ep(0x401A,U(0xffffffff,2)+F(0,0,2,2)+F(8,8,48,48))]
 return plus(records)
def write(name,image,consumer='direct',prefix=False):
 (P/(name+'.emf')).write_bytes(scene(image,consumer,prefix))
# B,G,R[,A] words; grayscale stores one intensity word per pixel. Constants
# deliberately include unequal bytes (mid-gray0x8080 and precision probes).
MAX=65535
samples={
 'gray':(0x101004,[H(0,0x8080),H(MAX,0x4040)],4),
 'rgb48':(0x10300c,[H(0,0,MAX,0,MAX,0),H(MAX,0,0,MAX,MAX,MAX)],12),
 'argb64':(0x34400d,[H(0,0,MAX,0x8080,0,MAX,0,MAX),H(MAX,0,0,0x4040,MAX,MAX,MAX,0)],16),
 'pargb64':(0x1a400e,[H(0,0,0x8080,0x8080,0,MAX,0,MAX),H(0x4040,0,0,0x4040,0,0,0,0)],16),
}
# Independent 8-bit straight-alpha controls: black/midgray,white/quartergray;
# red/green,blue/white; translucent red/opaquegreen,quarter-blue/transparent.
controls={
 'gray':[bytes([0,0,0,255,128,128,128,255]),bytes([255,255,255,255,64,64,64,255])],
 'rgb48':[bytes([0,0,255,255,0,255,0,255]),bytes([255,0,0,255,255,255,255,255])],
 'argb64':[bytes([0,0,255,128,0,255,0,255]),bytes([255,0,0,64,255,255,255,0])],
 'pargb64':[bytes([0,0,255,128,0,255,0,255]),bytes([255,0,0,64,0,0,0,0])],
}
for name,(fmt,rows,stride) in samples.items():
 for consumer in ['direct','texture','mapped']:
  suffix='' if consumer=='direct' else '-'+consumer
  write('high-depth-'+name+suffix,bitmap(fmt,rows,stride),consumer)
  write('high-depth-'+name+suffix+'-control',bitmap(0x26200a,controls[name],8),consumer)
 write('high-depth-'+name+'-negative',bitmap(fmt,rows,-stride))
 # Nonzero DWORD row padding must not become a source pixel.
 padded=[r+b'\xa5\x5a\xc3\x3c' for r in rows]
 write('high-depth-'+name+'-padded',bitmap(fmt,padded,stride+4))
# Low-order words distinguish source high-byte truncation from nearest/full-range
# normalization and13-bit LockBits assumptions. Controls are literal bytes.
precision=[H(0x00ff,0x7fff),H(0x2000,0x0101)]
write('high-depth-gray-precision',bitmap(0x101004,precision,4))
write('high-depth-gray-precision-control',bitmap(0x26200a,[bytes([0,0,0,255,127,127,127,255]),bytes([32,32,32,255,1,1,1,255])],8))
# Microsoft SDK and MS-EMFPLUS publish different PARGB constants; accept both
# exact documented values with identical source component bytes.
for consumer in ['direct','texture']:
 suffix='' if consumer=='direct' else '-'+consumer
 write('high-depth-pargb64-sdk'+suffix,bitmap(0x1c400e,samples['pargb64'][1],16),consumer)
# Quantize WORDs BEFORE unpremultiplication: alpha0x7f01→127,red0x3fff→63.
# A 16-bit ratio would produce a different red; the independent32-bit PARGB
# control contains literal63/127 premultiplied bytes, not computed color ratios.
nontrivial=[H(0,0,0x3fff,0x7f01,0,0x1111,0,0x7f01),H(0x00fe,0,0,0x00ff,0x4444,0x2222,0x1111,0x8080)]
write('high-depth-pargb64-precision',bitmap(0x1a400e,nontrivial,16))
write('high-depth-pargb64-precision-control',bitmap(0xe200b,[bytes([0,0,63,127,0,17,0,127]),bytes([0,0,0,0,68,34,17,128])],8))
# Each malformed object follows a successful red prefix; whole conversion must
# refuse instead of returning plausible prefix pixels. Framing stays valid.
bad={}
for name,(fmt,rows,stride) in samples.items():
 valid=bitmap(fmt,rows,stride)
 bad[name+'-truncated']=valid[:-1]
 bad[name+'-trailing']=valid+U(0)
 bad[name+'-short-stride']=bitmap(fmt,rows,stride-4)
 bad[name+'-unaligned-stride']=bitmap(fmt,[r+b'\0' for r in rows],stride+1)
 bad[name+'-zero-stride']=U(0xdbc01002,1)+I(2,2,0)+U(fmt,0)
 bad[name+'-min-stride']=U(0xdbc01002,1)+I(2,2,-2147483648)+U(fmt,0)
 bad[name+'-palette']=bitmap(fmt,rows,stride,extra=U(0,1,0xffff0000))
 bad[name+'-indexed-flag']=bitmap(fmt|0x10000,rows,stride)
 bad[name+'-overflow']=U(0xdbc01002,1)+I(2147483647,2147483647,2147483644)+U(fmt,0)
 bad[name+'-negative-width']=U(0xdbc01002,1)+I(-2,2,stride)+U(fmt,0)+b''.join(rows)
 bad[name+'-negative-height']=U(0xdbc01002,1)+I(2,-2,stride)+U(fmt,0)+b''.join(rows)
bad['pargb-undocumented-enum']=bitmap(0x18400e,samples['pargb64'][1],16)
# Preserve malformed coverage for the former sufficient-but-unaligned RGB24
# fixtures, now repaired to the protocol's mandatory DWORD stride.
rows24=[bytes([0,0,255,0,255,0,255,0,0]),bytes([255,255,255,0,0,0,0,255,255])]
for stride in [9,-9]:
 bad['rgb24-unaligned-'+('positive' if stride>0 else 'negative')]=bitmap(0x21808,rows24,stride,width=3)
for name,image in bad.items():
 write('high-depth-refused-'+name,image,prefix=True)
 if name.endswith('-truncated') or name.endswith('-palette'):
  write('high-depth-refused-texture-'+name,image,'texture',True)
print('Authored high-depth bitmap fixtures:',len(list(P.glob('high-depth-*.emf'))))
