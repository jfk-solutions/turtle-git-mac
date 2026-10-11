#!/usr/bin/env python3
"""Verify strict per-slice deployment validation, including legacy macOS commands."""
import argparse
import importlib.util
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('runtime_validator', Path(__file__).with_name('validate-git-runtime.py'))
validator = importlib.util.module_from_spec(spec); spec.loader.exec_module(validator)

def thin(arch, commands):
    payload = b''.join(commands)
    return struct.pack('<IIIIIIII', 0xfeedfacf, {'x86_64': 0x1000007, 'arm64': 0x100000c}[arch],
                       0, 2, len(commands), len(payload), 0, 0) + payload

def modern(version=0x000d0000, platform=1):
    return struct.pack('<IIIIII', 0x32, 24, platform, version, 0x001a0200, 0)

def legacy(version=0x000a0900):
    return struct.pack('<IIII', 0x24, 16, version, 0x000a0f00)

def universal(x86, arm):
    # Deliberately mixed command generations, as a universal archive may contain.
    first = 48; second = first + len(x86)
    return (struct.pack('>II', 0xcafebabe, 2)
            + struct.pack('>IIIII', 0x1000007, 0, first, len(x86), 0)
            + struct.pack('>IIIII', 0x100000c, 0, second, len(arm), 0) + x86 + arm)

class DeploymentTests(unittest.TestCase):
    def test_modern_and_legacy(self):
        self.assertEqual(validator.macos_minimum(thin('arm64', [modern()])), (13, 0, 0))
        self.assertEqual(validator.macos_minimum(thin('x86_64', [legacy()])), (10, 9, 0))

    def test_invalid_platform_missing_duplicate_and_truncated(self):
        cases = [[], [modern(platform=2)], [modern(), legacy()], [modern(), modern()],
                 [struct.pack('<IIII', 0x25, 16, 0x000d0000, 0)],
                 [struct.pack('<II', 0x32, 8)],
                 [struct.pack('<IIIIII', 0x32, 24, 1, 0x000d0000, 0, 1)]]
        for commands in cases:
            with self.subTest(commands=commands), self.assertRaises(ValueError):
                validator.macos_minimum(thin('arm64', commands))
        for data in [b'', thin('arm64', [modern()])[:-1]]:
            with self.assertRaises(ValueError): validator.macos_minimum(data)
        broken = bytearray(thin('arm64', [modern()]))
        struct.pack_into('<I', broken, 36, 32)
        with self.assertRaises(ValueError): validator.macos_minimum(broken)

    def test_both_slices_enforced_and_version_normalized(self):
        with tempfile.TemporaryDirectory(prefix='turtlegit-deployment-') as directory:
            path = Path(directory) / 'probe'
            path.write_bytes(universal(thin('x86_64', [legacy()]), thin('arm64', [modern()])))
            validator.audit_deployment(path, ['arm64', 'x86_64'], '13')
            validator.audit_deployment(path, ['arm64', 'x86_64'], '13.0.0')
            with self.assertRaisesRegex(ValueError, 'Architecture mismatch'):
                validator.audit_deployment(path, ['arm64'], '13.0')
            for arch in ['arm64', 'x86_64']:
                parts = {key: thin(key, [modern(0x000e0000) if key == arch else modern()]) for key in ['x86_64', 'arm64']}
                path.write_bytes(universal(parts['x86_64'], parts['arm64']))
                with self.assertRaisesRegex(ValueError, re.escape('[' + arch + ']')):
                    validator.audit_deployment(path, ['arm64', 'x86_64'], '13.0')
            path.write_bytes(universal(thin('x86_64', []), thin('arm64', [modern()])))
            with self.assertRaisesRegex(ValueError, 'x86_64'):
                validator.audit_deployment(path, ['arm64', 'x86_64'], '13.0')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path)
    args = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(DeploymentTests))
    if not result.wasSuccessful(): raise SystemExit(1)
    if args.runtime:
        # Cross-check actual Git and exact pinned publisher LFS slices against
        # explicit per-architecture otool, rather than its host-dependent default.
        for relative in ['bin/git', 'bin/git-lfs']:
            path = args.runtime / relative
            parts = validator.slices(path.read_bytes())
            validator.audit_deployment(path, ['arm64', 'x86_64'], '13.0')
            for arch, data in parts.items():
                output = subprocess.check_output(['/usr/bin/otool', '-arch', arch, '-l', str(path)], text=True)
                versions = []
                for block in re.split(r'^Load command \d+\s*$', output, flags=re.M):
                    if re.search(r'^\s*cmd LC_BUILD_VERSION\s*$', block, re.M):
                        versions += re.findall(r'^\s*minos\s+(\d+(?:\.\d+){0,2})\s*$', block, re.M)
                    elif re.search(r'^\s*cmd LC_VERSION_MIN_MACOSX\s*$', block, re.M):
                        versions += re.findall(r'^\s*version\s+(\d+(?:\.\d+){0,2})\s*$', block, re.M)
                expected = validator.macos_minimum(data)
                observed = [tuple(map(int, v.split('.'))) + (0,) * (3 - len(v.split('.'))) for v in versions]
                assert observed == [expected], (path, arch, observed, expected)
                print('%s [%s]: macOS %s; explicit otool agrees' % (relative, arch, '.'.join(map(str, expected))))
