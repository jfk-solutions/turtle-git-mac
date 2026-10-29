#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Hand-serialize only DIBProfiles/ wires; no renderer, tests or color oracle.

Original ICC bytes come from the separately authored profile generator. Run with
--profile-directory PATH on first generation; retained profiles/ copies suffice
for regeneration. Header/record framing is independent of the renderer decoder.
Profile declarations and input bytes are facts, not expected display colors.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parent
U = lambda *v: struct.pack('<' + 'I'*len(v), *v)
I = lambda *v: struct.pack('<' + 'i'*len(v), *v)
H = lambda *v: struct.pack('<' + 'H'*len(v), *v)
S = lambda *v: struct.pack('<' + 'h'*len(v), *v)
SRGB, EMBEDDED = 0x73524742, 0x4d424544
PIXELS = b''.join(bytes((b,g,r)) for row in [
    [(240,32,16),(32,224,64),(16,48,232),(128,128,128)],
    [(12,24,36),(220,180,40),(50,110,190),(248,248,248)],
    [(64,16,128),(180,80,120),(24,156,92),(208,208,208)],
    [(0,0,0),(255,255,255),(75,125,175),(160,100,40)],
] for r,g,b in row)


def sha(data): return hashlib.sha256(data).hexdigest()
def align(data, amount=4): return data + bytes((-len(data)) % amount)
def emf_record(kind, body=b''):
    body=align(body)
    return U(kind, 8+len(body))+body

def wmf_record(kind, body=b''):
    body=align(body,2)
    return U((6+len(body))//2)+H(kind)+body

def emf(records):
    records=[*records,emf_record(14,U(0,0,20))]
    return (U(1,88)+I(0,0,64,64)+I(0,0,1693,1693)
            +U(0x464d4520,0x10000,88+sum(map(len,records)),len(records)+1)
            +H(32,0)+U(0,0,0)+I(960,960,254,254)+b''.join(records))

def wmf(records):
    records=[wmf_record(0x20b,S(0,0)),wmf_record(0x20c,S(64,64)),*records,wmf_record(0)]
    place=U(0x9ac6cdd7)+H(0)+S(0,0,64,64)+H(96)+U(0)
    check=0
    for word in struct.unpack('<10H',place): check ^= word
    return (place+H(check)+H(1,9,0x300)+U((18+sum(map(len,records)))//2)
            +H(32)+U(max(len(r)//2 for r in records))+H(0)+b''.join(records))


def header(version=5, color_space=SRGB, profile_offset=0, profile_size=0,
           inactive_gamma=False):
    size=108 if version==4 else 124
    # Four top-down BGR24 pixels fill each DWORD-aligned 12-byte row exactly.
    base=U(size)+I(4,-4)+H(1,24)+U(0,len(PIXELS),0,0,0,0)
    # BI_RGB masks are inactive. Explicit sRGB likewise ignores endpoints/gamma.
    endpoints=U(*range(1,10)) if inactive_gamma else bytes(36)
    gamma=U(0x10000,0x20000,0x30000) if inactive_gamma else bytes(12)
    value=base+U(0,0,0,0,color_space)+endpoints+gamma
    if version==5: value += U(4,profile_offset,profile_size,0)
    assert len(value)==size
    return value


def dib(variant, profiles):
    version=4 if variant.startswith('v4') else 5
    profile_name=None;placement='none';declared_offset=0;declared_size=0
    profile=b'';cs=SRGB
    if variant.startswith('embedded-'):
        profile_name,placement=variant.removeprefix('embedded-').rsplit('-',1)
        profile=profiles[profile_name];cs=EMBEDDED
        declared_offset=124 if placement=='before' else 124+len(PIXELS)
        declared_size=len(profile)
    elif variant=='v5-srgb-inactive-profile':
        # These fields are inactive for sRGB, including deliberately huge values.
        declared_offset=0xfffffff0;declared_size=0xffffffff
    elif variant.startswith('malformed-'):
        cs=EMBEDDED
        if variant=='malformed-profile-overlap-bits':declared_offset,declared_size=124,16
        elif variant=='malformed-profile-inside-header':declared_offset,declared_size=100,24
        elif variant=='malformed-profile-overflow':declared_offset,declared_size=0xfffffff0,64
        elif variant=='malformed-profile-truncated':declared_offset,declared_size=124+len(PIXELS),32;profile=b'ICC!'
        else:raise ValueError(variant)
        placement='after'
    info=header(version,cs,declared_offset,declared_size,variant=='v4-srgb-inactive-gamma')
    if placement=='before':info += align(profile)
    tail=align(profile) if placement=='after' else b''
    packed=info+PIXELS+tail
    return info,PIXELS,tail,dict(headerBytes=108 if version==4 else 124,
        infoBytes=len(info),pixelBytes=len(PIXELS),packedBytes=len(packed),
        colorSpace=cs,profile=profile_name,profilePlacement=placement,
        profileData=declared_offset,profileSize=declared_size,
        profilePayloadSHA256=sha(profile) if profile else None)


def scene(consumer, variant, profiles, icm='default'):
    info,bits,tail,meta=dib(variant,profiles)
    is_wmf=consumer.startswith('wmf-')
    if is_wmf:
        # Source white background, then red sentinel; no ICM record exists in WMF.
        prefix=[wmf_record(0x12d,H(0x8008)),wmf_record(0x12d,H(0x8000)),
                wmf_record(0x41b,S(64,64,0,0)),wmf_record(0x2fc,H(0)+U(255)+H(0)),
                wmf_record(0x12d,H(0)),wmf_record(0x41b,S(6,6,0,0))]
        packed=info+bits+tail
        # A packed DIB always starts pixels immediately after its header/table.
        # Prepending ICC bytes does NOT relocate the implicit pixel address.
        implicit=meta['headerBytes']
        profile_start,profile_end=meta['profileData'],meta['profileData']+meta['profileSize']
        meta.update(implicitBitsOffsetFromDIB=implicit,serializedPixelOffsetFromDIB=len(info),
                    implicitPixelBytes=len(bits),implicitPixelSHA256=sha(packed[implicit:implicit+len(bits)]),
                    declaredProfileIntersectsImplicitPixels=bool(meta['profileSize'] and profile_start<implicit+len(bits) and implicit<profile_end))
        if consumer=='wmf-raster':record=wmf_record(0xf43,U(0x00cc0020)+H(0)+S(4,4,0,0,48,48,8,8)+packed)
        elif consumer=='wmf-scanlines':record=wmf_record(0xd33,H(0,4,0)+S(0,0)+H(4,4)+S(8,8)+packed)
        elif consumer=='wmf-brush':
            record=wmf_record(0x142,H(5,0)+packed)
            return wmf(prefix+[record,wmf_record(0x12d,H(1)),wmf_record(0x41b,S(56,56,8,8))]),meta
        else:raise ValueError(consumer)
        return wmf(prefix+[record]),meta
    prefix=[emf_record(37,U(0x80000008)),emf_record(37,U(0x80000000)),
            emf_record(43,I(0,0,64,64)),emf_record(39,U(2,0,255,0)),
            emf_record(37,U(2)),emf_record(43,I(0,0,6,6))]
    icm_sequences={
        'default':[], 'off':[('mode',1)], 'on':[('mode',2)],
        'on-query':[('mode',2),('mode',3)],
        'off-query':[('mode',1),('mode',3)],
        'on-done-outside':[('mode',2),('mode',4)],
        'off-done-outside':[('mode',1),('mode',4)],
        'save-on-restore-off':[('mode',1),('save',None),('mode',2),('restore',-1)],
        'save-off-restore-on':[('mode',2),('save',None),('mode',1),('restore',-1)],
    }
    state_records=icm_sequences[icm]
    for operation,value in state_records:
        prefix.append(emf_record(98,U(value)) if operation=='mode'
                      else emf_record(33) if operation=='save' else emf_record(34,I(value)))
    offset={'emf-raster':80,'emf-scanlines':76,'emf-brush':32}[consumer]
    off_bits=offset+len(info)
    meta.update(offBmiSrc=offset,cbBmiSrc=len(info),offBitsSrc=off_bits,cbBitsSrc=len(bits),recordedICM=icm,
                stateRecords=[dict(operation=op,value=value) for op,value in state_records])
    if consumer=='emf-raster':body=I(0,0,64,64)+I(8,8,0,0,4,4)+U(offset,len(info),off_bits,len(bits),0,0x00cc0020)+I(48,48);kind=81
    elif consumer=='emf-scanlines':body=I(0,0,64,64)+I(8,8,0,0,4,4)+U(offset,len(info),off_bits,len(bits),0,0,4);kind=80
    elif consumer=='emf-brush':body=U(1,0,offset,len(info),off_bits,len(bits));kind=94
    else:raise ValueError(consumer)
    assert len(body)+8==offset
    records=prefix+[emf_record(kind,body+info+bits+tail)]
    if consumer=='emf-brush':records += [emf_record(37,U(1)),emf_record(43,I(8,8,56,56))]
    return emf(records),meta


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile-directory',type=Path)
    parser.add_argument('--output',type=Path,default=ROOT/'DIBProfiles')
    args=parser.parse_args();output=args.output
    source=args.profile_directory or output/'profiles'
    profiles={name:(source/(name+'.icc')).read_bytes() for name in ('srgb','linear-rgb')}
    # ICC header lengths are independent input framing, not color validation.
    for name,data in profiles.items():
        if len(data)<128 or struct.unpack_from('>I',data)[0]!=len(data) or data[36:40]!=b'acsp':
            raise ValueError('Unexpected original ICC framing: '+name)
    output.mkdir(parents=True,exist_ok=True);(output/'profiles').mkdir(exist_ok=True)
    for name,data in profiles.items():(output/'profiles'/(name+'.icc')).write_bytes(data)
    consumers=['emf-raster','emf-scanlines','emf-brush','wmf-raster','wmf-scanlines','wmf-brush']
    base=['v4-srgb','v5-srgb','v4-srgb-inactive-gamma','v5-srgb-inactive-profile']
    embedded=['embedded-'+name+'-'+placement for name in profiles for placement in ('before','after')]
    malformed=['malformed-profile-overlap-bits','malformed-profile-inside-header','malformed-profile-overflow','malformed-profile-truncated']
    cases=[]
    def emit(consumer,variant,icm='default'):
        wire,fields=scene(consumer,variant,profiles,icm)
        name=consumer+'-'+variant+('' if icm=='default' else '-icm-'+icm)+('.wmf' if consumer.startswith('wmf') else '.emf')
        (output/name).write_bytes(wire)
        classification=('malformed-active-profile-span:'+variant.removeprefix('malformed-profile-')
                        if variant.startswith('malformed-') else 'valid-inactive-colorspace-metadata'
                        if variant.startswith(('v4-srgb','v5-srgb')) else 'valid-embedded-profile-span')
        packed_before=consumer.startswith('wmf') and fields['profilePlacement']=='before'
        if packed_before:classification='malformed-active-profile-span:packed-profile-before-bits'
        cases.append(dict(file=name,consumer=consumer,family=consumer.split('-',1)[1],container='wmf' if consumer.startswith('wmf') else 'emf',
                          variant=variant,layout=fields['profilePlacement'],framingClassification=classification,
                          bytes=len(wire),sha256=sha(wire),fields=fields,
                          role='malformed-boundary-discriminator' if variant.startswith('malformed-') or packed_before else 'framing-and-policy-discriminator'))
    for consumer in consumers:
        for variant in base+embedded+malformed:emit(consumer,variant)
    for name in profiles:
        for placement in ('before','after'):
            for icm in ('off','on'):emit('emf-raster','embedded-'+name+'-'+placement,icm)
    for state in ('on-query','off-query','on-done-outside','off-done-outside','save-on-restore-off','save-off-restore-on'):
        emit('emf-raster','embedded-linear-rgb-before',state)
    manifest=dict(schemaVersion=1,canvas=[64,64],sourceBitmap=dict(width=4,height=-4,depth=24,stride=12,bytes=len(PIXELS),sha256=sha(PIXELS),topDownBGR24Hex=PIXELS.hex()),
        colorExpectations='None: Windows playback and consumer-contract evidence are required before assigning display expectations.',
        profileProvenance='Original profiles from docs/qa/metafile-dib-profile-reference-2026-10-29/generate-profiles.py; retained exact bytes for deterministic regeneration.',
        profiles=[dict(file='profiles/'+name+'.icc',bytes=len(data),sha256=sha(data)) for name,data in profiles.items()],
        caseCount=len(cases),cases=cases)
    (output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print('Generated',len(cases),'independent DIB-profile wires in',output)

if __name__=='__main__':main()
