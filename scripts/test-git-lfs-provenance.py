#!/usr/bin/env python3
"""Check publisher provenance survives signing and rejects modified executable code."""
import argparse
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
from git_lfs_runtime import ROOT

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('runtime', type=Path)
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='turtlegit-lfs-provenance-') as temporary:
    runtime = Path(temporary) / 'Git'
    shutil.copytree(args.runtime, runtime, symlinks=True)
    binary = runtime / 'bin/git-lfs'
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--options', 'runtime', binary], check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', binary], check=True)
    audit = ['/usr/bin/python3', ROOT / 'scripts/validate-git-lfs-runtime.py', runtime]
    subprocess.run(audit, check=True)
    data = bytearray(binary.read_bytes())
    # Mutate actual code in the first universal slice, rather than signature bytes.
    magic = data[:4]
    assert magic == b'\xca\xfe\xba\xbe'
    base = struct.unpack_from('>I', data, 16)[0]
    cursor = base + 32
    modified = False
    for _ in range(struct.unpack_from('<I', data, base + 16)[0]):
        command, size = struct.unpack_from('<II', data, cursor)
        if command == 0x19:
            for index in range(struct.unpack_from('<I', data, cursor + 64)[0]):
                section = cursor + 72 + index * 80
                if data[section:section + 16].rstrip(b'\0') == b'__text':
                    offset = struct.unpack_from('<I', data, section + 48)[0]
                    data[base + offset] ^= 1
                    modified = True
                    break
        if modified:
            break
        cursor += size
    assert modified
    binary.write_bytes(data)
    rejected = subprocess.run(audit, capture_output=True, text=True)
    assert rejected.returncode != 0 and 'Changed Git LFS code/data or loader' in rejected.stderr, rejected.stderr
print('PASS: ad-hoc replacement signature verifies and retains publisher provenance; modified code rejected before helper execution. Signed sandbox acceptance remains pending.')
