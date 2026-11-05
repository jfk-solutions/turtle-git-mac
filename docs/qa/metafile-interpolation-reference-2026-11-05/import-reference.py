#!/usr/bin/env python3
"""Import original Windows bytes; never invoke or derive pixels from TurtleGit."""
import argparse
import hashlib
import json
from pathlib import Path, PureWindowsPath
import struct

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, default=ROOT/'Tests/TurtleGitCoreTests/Fixtures/Metafile/Interpolation/Windows')
parser.add_argument('--check', action='store_true')
args = parser.parse_args()

def digest(data): return hashlib.sha256(data).hexdigest()
def read_json(path): return json.loads(path.read_text(encoding='utf-8-sig'))
def capture(name):
    folder = HERE/name
    entries = read_json(folder/'sha256.json')
    hashes = {PureWindowsPath(entry['Path']).name: entry['Hash'].lower() for entry in entries}
    def verified(name):
        path = folder/'output'/name
        content = path.read_bytes()
        assert digest(content) == hashes[name], name
        return content
    return folder, hashes, verified

original, original_hashes, original_bytes = capture('windows-capture96')
variants, variant_hashes, variant_bytes = capture('windows-wire-capture')
native = read_json(original/'output/interpolation-observations.json')
aliases = read_json(variants/'output/wire-variant-observations.json')
assert native['completedCaseCount'] == len(native['cases']) == 192
assert aliases['completedCaseCount'] == len(aliases['cases']) == 192
assert (native['width'], native['height']) == (32, 24)
manifest = {
    'schema': 1, 'width': 32, 'height': 24,
    'pixel_format': 'Complete top-down straight RGBA, including zero-alpha RGB; copied without alteration',
    'source': 'Independent Windows GDI+ separate Metafile(file) natural and Bitmap(file,FALSE)+GetRawFormat Picture consumers at32x24; recording HDC from Bitmap SetResolution96 then Graphics.GetHDC; no TurtleGit renderer',
    'legacy_aliases': 'expected and rgba_sha256 refer explicitly to natural playback. Picture consumers must use expectedPicture/picture_sha256; natural/Picture byte equality is not assumed.',
    'platform': read_json(original/'environment.json'),
    'runtime_versions': read_json(original/'runtime-versions.json'),
    'runtime_sha256': {name: original_hashes[name] for name in ['gdiplus.dll','gdi32.dll','win32u.dll']},
    'source_sha256': {name: original_hashes[name] for name in ['InterpolationReference96DPI.cpp','InterpolationReference96DPI.exe','compiler.txt']},
    'alias_source_sha256': {name: variant_hashes[name] for name in ['InterpolationReference.cpp','WireVariants.cpp','WireVariants.exe','compiler.txt']},
    'frame_policy': 'Native explicit output canvas32x24; recorded frame100mm(0,0,610,446), device1728x1084 pixels and340x210mm yield natural32x24 by round(frame*recordedDevicePixels/(deviceMM*100))+1. No header or RGBA padding/cropping/normalization is applied; ink bounds are retained separately.',
    'remaining': ['Initial all-down profile differences are retained in analysis. Independent NZN Float32 profile matches all48 opaque+alpha nearest natural cases with zero pixel differences; the Mac renderer checkpoint is pending. Exhaustive affine behavior beyond this corpus is not proved. No case is omitted to make a renderer pass.'],
    'cases': [],
}
outputs = {}
def add(name, case, wire, rgba, picture, category):
    assert '/' not in name and '\\' not in name
    assert len(rgba) == len(picture) == 32*24*4
    assert struct.unpack_from('<I', wire, 0)[0] == 1
    record = dict(case, name=name, category=category, file=name+'.emf',
                  expectedNatural=name+'.natural.rgba', natural_sha256=digest(rgba),
                  expectedPicture=name+'.picture.rgba', picture_sha256=digest(picture),
                  expected=name+'.natural.rgba', rgba_sha256=digest(rgba),
                  emf_sha256=digest(wire),
                  header_bounds=list(struct.unpack_from('<4i',wire,8)),
                  header_frame_100mm=list(struct.unpack_from('<4i',wire,24)),
                  header_device_pixels=list(struct.unpack_from('<2i',wire,72)),
                  header_device_mm=list(struct.unpack_from('<2i',wire,80)))
    manifest['cases'].append(record); outputs[name+'.emf']=wire
    outputs[name+'.natural.rgba']=rgba; outputs[name+'.picture.rgba']=picture
for case in native['cases']:
    name=case['name']
    add(name,case,original_bytes(name+'.emf'),original_bytes(name+'-natural.rgba'),original_bytes(name+'-picture.rgba'),'native-api')
for case in aliases['cases']:
    if case['mode'] != 1: continue
    name=case['name']; original_wire=original_bytes(case['source']+'.emf'); wire=variant_bytes(name+'.emf')
    assert len(wire)==len(original_wire)
    assert sum(a!=b for a,b in zip(wire,original_wire))==1
    add(name,case,wire,variant_bytes(name+'-natural.rgba'),variant_bytes(name+'-picture.rgba'),'raw-interpolation-alias1')
if (HERE/'windows-pixel-capture/output/pixel-alias-observations.json').exists():
    pixel_folder, pixel_hashes, pixel_bytes = capture('windows-pixel-capture')
    pixels=read_json(pixel_folder/'output/pixel-alias-observations.json')
    assert pixels['completedCaseCount']==len(pixels['cases'])==32
    manifest['pixel_alias_source_sha256']={name:pixel_hashes[name] for name in ['InterpolationReference.cpp','PixelOffsetVariants.cpp','PixelOffsetVariants.exe','compiler.txt']}
    for case in pixels['cases']:
        name=case['name']; wire=pixel_bytes(name+'.emf'); old=original_bytes(case['source']+'.emf')
        assert len(wire)==len(old) and sum(a!=b for a,b in zip(wire,old))==1
        add(name,case,wire,pixel_bytes(name+'-natural.rgba'),pixel_bytes(name+'-picture.rgba'),'raw-pixeloffset-alias2')
if (HERE/'windows-varied-capture/output/interpolation-observations.json').exists():
    varied_folder, varied_hashes, varied_bytes = capture('windows-varied-capture')
    varied=read_json(varied_folder/'output/interpolation-observations.json')
    assert varied['completedCaseCount']==len(varied['cases'])==32
    manifest['varied_source_sha256']={name:varied_hashes[name] for name in ['VariedReference.cpp','VariedReference.exe','compiler.txt']}
    manifest['varied_source_rgba']=[[70,140,210,248],[37,91,143,127],[197,63,121,7],[254,195,83,64]]
    for case in varied['cases']:
        assert case['directState']['sourceRGBA']==case['recordedState']['sourceRGBA']==manifest['varied_source_rgba']
        name=case['name']
        add(name,case,varied_bytes(name+'.emf'),varied_bytes(name+'-natural.rgba'),varied_bytes(name+'-picture.rgba'),'varied-native-api')
outputs['manifest.json']=(json.dumps(manifest,indent=2)+'\n').encode()
for name, content in outputs.items():
    target=args.output/name
    if args.check:
        assert target.read_bytes()==content,target
    else:
        if target.exists():
            if name=='manifest.json' and target.read_bytes()!=content:
                previous=json.loads(target.read_text())
                current={case['name']:case for case in manifest['cases']}
                for case in previous['cases']:
                    assert case['name'] in current
                    for field in ['emf_sha256','rgba_sha256','file','expected']:
                        assert case[field]==current[case['name']][field], 'Refuse changed existing case: '+case['name']
                target.write_bytes(content)
            else: assert target.read_bytes()==content, 'Refuse changed existing reference: '+str(target)
        else:
            target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(content)
print(('Checked' if args.check else 'Imported')+' '+str(len(manifest['cases']))+' original Windows cases; no pixel modifications.')
