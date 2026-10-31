#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Derive explicit white/PATCOPY controls; never rewrite any original wire.
No renderer, screenshot, application or test process is invoked.
"""
from pathlib import Path
import hashlib,json,struct
P=Path(__file__).parent
U=lambda *v:struct.pack('<'+'I'*len(v),*v)
H=lambda *v:struct.pack('<'+'H'*len(v),*v)
S=lambda *v:struct.pack('<'+'h'*len(v),*v)
def record(kind,body=b''):
    assert len(body)%2==0
    return U((len(body)+6)//2)+H(kind)+body
def records(data):
    assert data[:4]==U(0x9ac6cdd7)
    result=[];offset=40
    while offset<len(data):
        words,kind=struct.unpack_from('<IH',data,offset);assert words>=3 and offset+words*2<=len(data)
        result.append((kind,data[offset+6:offset+words*2],data[offset:offset+words*2]));offset+=words*2
    assert offset==len(data) and result[-1][0]==0
    return result
# Save/white stock brush/PATCOPY/Restore: no object allocation, clip, mapping,
# current pen, palette, source data or later selected brush is changed.
white=[record(0x1e),record(0x12d,H(0x8000)),record(0x61d,U(0x00f00021)+S(64,64,0,0)),record(0x127,S(-1))]
walls=[(8,8,56,10),(8,54,56,56),(8,10,10,54),(54,10,56,54),(30,10,34,54)]
def derive(original,sealed):
    rs=records(original);assert [r[0] for r in rs[:2]]==[0x20b,0x20c]
    output=[r[2] for r in rs[:2]]+white;replaced=[]
    for kind,body,raw in rs[2:]:
        if sealed and kind==0x41b:
            bottom,right,top,left=struct.unpack('<4h',body)
            if (left,top,right,bottom) in walls:
                raw=record(0x61d,U(0x00f00021)+S(bottom-top,right-left,top,left));replaced.append([left,top,right,bottom])
        output.append(raw)
    if sealed:assert replaced==[list(w) for w in walls]
    result=bytearray(original[:40]+b''.join(output))
    struct.pack_into('<I',result,28,(len(result)-22)//2)
    struct.pack_into('<I',result,34,max(len(r)//2 for r in output))
    return bytes(result),replaced
specs=[('wmf-classic-flood-'+n+'.wmf','wmf-classic-flood-'+n+'-sealed-white-patcopy-control.wmf',True) for n in ['surface','border','legacy-border','hatch']]
specs += [('unsupported-raster-wmf-without-bitmap-source-'+kind+'.wmf','classic-gdi-empty-prior-'+kind+'-white-patcopy-control.wmf',False) for kind in ['bitblt','stretchblt']]
specs += [('classic-scanlines-wmf-full-bottom.wmf','classic-gdi-scanlines-full-white-patcopy-control.wmf',False)]
# The source manifest covers all connected original scanline/region/flood/brush/
# Bitmap16 wires, not merely the seven derivative parents.
selected=lambda n:n.endswith(('.wmf','.emf')) and (n.startswith(('classic-scanlines-','classic-region-','classic-flood-','wmf-classic-region-','wmf-classic-flood-','wmf-classic-patternbrush-','classic-monobrush-','classic-patternbrush-','wmf-bitmap16-')) or n.startswith('unsupported-raster-wmf-without-bitmap-source-'))
derivative_names={s[1] for s in specs}
originals={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(P.iterdir()) if selected(p.name) and p.name not in derivative_names}
result=[]
for source,target,sealed in specs:
    before=(P/source).read_bytes();value,replaced=derive(before,sealed)
    dest=P/target
    if dest.exists() and dest.read_bytes()!=value:raise RuntimeError('Refuse rewriting a different control: '+target)
    dest.write_bytes(value)
    assert (P/source).read_bytes()==before
    result.append(dict(source=source,control=target,source_sha256=hashlib.sha256(before).hexdigest(),control_sha256=hashlib.sha256(value).hexdigest(),replaced_black_wall_rectangles=replaced))
assert all(hashlib.sha256((P/n).read_bytes()).hexdigest()==h for n,h in originals.items())
(P/'classic-gdi-contract-controls.json').write_text(json.dumps(dict(kind='ExplicitClassicGDIBackgroundAndSealedWallControls',originals=originals,controls=result),indent=2)+'\n')
print('Generated seven explicit controls; preserved '+str(len(originals))+' original wires byte-for-byte.')
