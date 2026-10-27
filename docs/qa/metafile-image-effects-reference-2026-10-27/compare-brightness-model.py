#!/usr/bin/env python3
"""Compare the original normalized Float32 model with captured Windows LUT bytes."""
import json
from pathlib import Path
import re
import struct
import sys

f32 = lambda x: struct.unpack('<f', struct.pack('<f', x))[0]
root = Path(sys.argv[1])
results = []
for path in sorted(root.glob('bc-*.lut')):
    match = re.fullmatch(r'bc-b(-?\d+)-c(-?\d+)\.lut', path.name)
    if not match:
        raise ValueError('Unexpected native table name')
    brightness, contrast = map(int, match.groups())
    native = path.read_bytes()
    assert len(native) == 1024
    assert native[:256] == native[256:512] == native[512:768]
    assert native[768:] == bytes(range(256)), 'Native alpha was not identity'
    if contrast != 100:
        slope = f32(100 / (100 - contrast) if contrast > 0 else (100 + contrast) / 100)
        midpoint = f32(f32(1 - slope) / 2)
        scale = f32(f32(slope + 1) / 2)
        offset = f32(midpoint + f32(f32(brightness / 255) * scale))
    observed = []
    for x in range(256):
        if brightness in (-255, 255):
            y = 0 if brightness < 0 else 255
        elif contrast == 100:
            threshold = 2 * x + brightness
            y = 0 if threshold < 255 else 255 if threshold > 255 else 128
        else:
            scaled = f32(f32(x / 255) * slope)
            shifted = f32(scaled + offset)
            y = max(0, min(255, round(f32(shifted * 255))))
        observed.append(y)
    differences = [abs(a-b) for a, b in zip(observed, native[:256])]
    results.append(dict(brightness=brightness, contrast=contrast,
                        different=sum(d != 0 for d in differences), maximum=max(differences)))
assert len(results) == 81, 'Incomplete captured parameter grid'
print(json.dumps(dict(scope='Original Float32 mathematical model, not complete macOS decoder pixel acceptance',
                     pairs=len(results), scalar_samples=len(results)*256,
                     different=sum(x['different'] for x in results),
                     maximum=max(x['maximum'] for x in results),
                     contrast100_different=sum(x['different'] for x in results if x['contrast']==100),
                     cases=results), indent=2))
