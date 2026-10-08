"""Pinned Git LFS archive and Mach-O provenance helpers (Python standard library)."""
import base64
import hashlib
import json
from pathlib import Path, PurePosixPath
import struct
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
def digest(data): return hashlib.sha256(data).hexdigest()
def pin(): return json.loads((ROOT / 'Configuration/GitLFSRuntime.json').read_text())
def cached(record):
    path = ROOT / 'build/git-lfs-source' / record['filename']; path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        with urllib.request.urlopen(record['url'], timeout=45) as response: data = response.read()
        if digest(data) != record['sha256']: raise ValueError('Publisher checksum mismatch: ' + record['filename'])
        path.write_bytes(data)
    if digest(path.read_bytes()) != record['sha256']: raise ValueError('Cached checksum mismatch: ' + record['filename'])
    return path
def archive_names(archive):
    names = archive.namelist()
    if len(names) != len(set(names)): raise ValueError('Duplicate archive members')
    for name in names:
        path = PurePosixPath(name)
        if path.is_absolute() or '..' in path.parts or '\\' in name or '\n' in name:
            raise ValueError('Unsafe archive member: ' + name)
    return names
def module_hash(archive):
    lines = [digest(archive.read(name)) + '  ' + name + '\n' for name in sorted(archive_names(archive)) if not name.endswith('/')]
    return 'h1:' + base64.b64encode(hashlib.sha256(''.join(lines).encode()).digest()).decode()
def slices(data):
    magic = data[:4]
    if magic == b'\xcf\xfa\xed\xfe':
        cpu = struct.unpack_from('<I', data, 4)[0]
        return { {0x1000007: 'x86_64', 0x100000c: 'arm64'}[cpu]: data }
    if magic not in [b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf']: raise ValueError('Expected 64-bit Mach-O')
    count = struct.unpack_from('>I', data, 4)[0]; result = {}
    for index in range(count):
        if magic[-1] == 0xbe: cpu, _, offset, size, _ = struct.unpack_from('>IIIII', data, 8 + index * 20)
        else: cpu, _, offset, size, _, _ = struct.unpack_from('>IIQQII', data, 8 + index * 32)
        arch = {0x1000007: 'x86_64', 0x100000c: 'arm64'}[cpu]
        if arch in result or offset + size > len(data): raise ValueError('Invalid fat slice')
        result[arch] = data[offset:offset + size]
    return result
def fingerprint(data):
    """Bind code/data and loader commands while allowing replacement signatures."""
    if data[:4] != b'\xcf\xfa\xed\xfe': raise ValueError('Expected thin 64-bit Mach-O')
    commands = []; sections = {}; cursor = 32
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        cmd, size = struct.unpack_from('<II', data, cursor)
        if size < 8 or cursor + size > len(data): raise ValueError('Invalid Mach-O load command')
        segment = data[cursor + 8:cursor + 24].rstrip(b'\0') if cmd == 0x19 else None
        if cmd != 0x1d and segment != b'__LINKEDIT': commands.append(digest(data[cursor:cursor + size]))
        if cmd == 0x19:
            for index in range(struct.unpack_from('<I', data, cursor + 64)[0]):
                entry = struct.unpack_from('<16s16sQQIIIIIIII', data, cursor + 72 + index * 80)
                name = entry[1].rstrip(b'\0').decode() + '/' + entry[0].rstrip(b'\0').decode()
                length, offset, flags = entry[3], entry[4], entry[8]
                if flags & 255 in [1, 12, 18]: payload = b'' # zero-fill sections have no disk bytes
                else:
                    if offset + length > len(data): raise ValueError('Invalid Mach-O section')
                    payload = data[offset:offset + length]
                if name in sections: raise ValueError('Duplicate Mach-O section')
                sections[name] = digest(payload)
        cursor += size
    return {'commands': commands, 'sections': sections}
def build_info(data):
    cursor = data.find(b'\xff Go buildinf:')
    if cursor < 0 or data[cursor + 15] & 2 == 0: raise ValueError('Missing inline Go build info')
    def string(offset):
        length = 0
        for shift in range(0, 70, 7):
            byte = data[offset]; offset += 1; length |= (byte & 127) << shift
            if byte < 128:
                if offset + length > len(data): raise ValueError('Invalid Go string length')
                return data[offset:offset + length], offset + length
        raise ValueError('Invalid Go varint')
    version, cursor = string(cursor + 32); info, _ = string(cursor)
    lines = info[16:-16].decode().splitlines()
    modules = dict(line.split('\t')[1:3] for line in lines if line.startswith('dep\t') and '\t(devel)\t' not in line)
    return version.decode(), modules
