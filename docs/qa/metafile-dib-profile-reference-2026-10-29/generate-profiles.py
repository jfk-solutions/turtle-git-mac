#!/usr/bin/env python3
"""Original ICC v2 matrix/TRC profiles for the DIB color-policy discriminator.

Standard sRGB primaries adapted to D50; transfer curves distinguish encoded
sRGB from linear RGB. No vendor profile bytes or private device data are used.
These are reference inputs, not proposed display-profile replacements.
"""
from pathlib import Path
import hashlib
import json
import struct

folder = Path(__file__).resolve().parent
u32 = lambda value: struct.pack('>I', value)
fixed = lambda value: struct.pack('>i', round(value * 65536))

def xyz(values):
    return b'XYZ ' + bytes(4) + b''.join(fixed(value) for value in values)

def description(text):
    ascii_text = text.encode('ascii') + b'\0'
    return b'desc' + bytes(4) + u32(len(ascii_text)) + ascii_text + bytes(4 + 4 + 2 + 1 + 67)

def profile(linear):
    name = 'TurtleGit original linear RGB reference' if linear else 'TurtleGit original sRGB reference'
    if linear:
        curve = b'curv' + bytes(4) + u32(1) + struct.pack('>H', 256)
    else:
        samples = []
        for index in range(4096):
            x = index / 4095
            y = x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4
            samples.append(round(y * 65535))
        curve = b'curv' + bytes(4) + u32(len(samples)) + struct.pack('>' + 'H' * len(samples), *samples)
    tags = [
        (b'desc', description(name)),
        (b'cprt', b'text' + bytes(4) + b'Original TurtleGit reference data; freely reusable.\0'),
        (b'wtpt', xyz((0.9642, 1.0, 0.8249))),
        (b'rXYZ', xyz((0.4360747, 0.2225045, 0.0139322))),
        (b'gXYZ', xyz((0.3850649, 0.7168786, 0.0971045))),
        (b'bXYZ', xyz((0.1430804, 0.0606169, 0.7141733))),
        (b'rTRC', curve), (b'gTRC', curve), (b'bTRC', curve),
    ]
    header = bytearray(128)
    header[8:12] = u32(0x02400000)
    header[12:24] = b'mntrRGB XYZ '
    header[24:36] = struct.pack('>6H', 2026, 10, 29, 0, 0, 0)
    header[36:40] = b'acsp'
    header[40:44] = b'MSFT'
    header[48:52] = b'TGIT'
    header[68:80] = b''.join(fixed(value) for value in (0.9642, 1.0, 0.8249))
    header[80:84] = b'TGIT'
    offset = 128 + 4 + len(tags) * 12
    records, payload = [], bytearray()
    for name, data in tags:
        records.append(name + u32(offset + len(payload)) + u32(len(data)))
        payload.extend(data)
        payload.extend(bytes((-len(payload)) % 4))
    result = header + u32(len(tags)) + b''.join(records) + payload
    result[0:4] = u32(len(result))
    return bytes(result)

manifest = {'purpose': __doc__.strip(), 'profiles': []}
for name, linear in [('srgb.icc', False), ('linear-rgb.icc', True)]:
    data = profile(linear)
    (folder / name).write_bytes(data)
    manifest['profiles'].append({'file': name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(), 'linear_transfer': linear})
(folder / 'profiles.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest['profiles']))
