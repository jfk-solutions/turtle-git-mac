#!/usr/bin/env python3
"""Check the C++ matcher, corresponding source, linkage and protocol fixtures."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('runtime', type=pathlib.Path)
parser.add_argument('--all-architectures', action='store_true', help='Also execute both slices; requires Rosetta on Apple Silicon.')
args = parser.parse_args()
runtime = args.runtime
manifest = json.loads((runtime / 'provenance.json').read_text())
binary = runtime / 'issue-regex'
source = 'Sources/TurtleGitIssueRegex/main.cpp'
for file in (ROOT / source, runtime / 'Sources/build' / source):
    assert hashlib.sha256(file.read_bytes()).hexdigest() == manifest['source_sha256'], 'Issue matcher source mismatch'
assert (runtime / 'LICENSE').read_bytes() == (ROOT / 'LICENSE').read_bytes()
assert (runtime / 'Sources/build/LICENSE').read_bytes() == (ROOT / 'LICENSE').read_bytes()
for name in ('build-issue-regex-runtime.py', 'validate-issue-regex-runtime.py'):
    assert (runtime / 'Sources/build/scripts' / name).read_bytes() == (ROOT / 'scripts' / name).read_bytes()
assert hashlib.sha256(binary.read_bytes()).hexdigest() == manifest['binary_sha256'], 'Issue matcher binary mismatch'
architectures = set(subprocess.check_output(['lipo', '-archs', binary], text=True).split())
assert architectures == set(manifest['architectures']) == {'arm64', 'x86_64'}
versions = subprocess.check_output(['xcrun', 'vtool', '-show-build', binary], text=True)
assert re.findall(r'\bminos\s+([0-9.]+)', versions) == ['13.0', '13.0']
for line in subprocess.check_output(['otool', '-L', binary], text=True).splitlines():
    if line.startswith('\t'):
        assert line.strip().split(' (')[0].startswith(('/usr/lib/', '/System/Library/')), line
if manifest.get('signed'):
    subprocess.run(['codesign', '--verify', '--strict', binary], check=True)
    if manifest.get('sandbox_inherited'):
        output = subprocess.check_output(['codesign', '-d', '--entitlements', ':-', binary], stderr=subprocess.STDOUT)
        start = output.index(b'<?xml')
        end = output.index(b'</plist>', start) + len(b'</plist>')
        assert plistlib.loads(output[start:end]) == {'com.apple.security.app-sandbox': True, 'com.apple.security.inherit': True}
        print('IssueRegex: inherited sandbox signature and source verified; native signed app acceptance remains required.')
        raise SystemExit(0)
prefixes = [[], ['/usr/bin/arch', '-arm64'], ['/usr/bin/arch', '-x86_64']] if args.all_architectures else [[]]
with tempfile.TemporaryDirectory(prefix='TurtleGitIssueRegexAudit-') as folder:
    inputs = [pathlib.Path(folder) / str(index) for index in range(3)]
    fixtures = [
        (r'[Ii]ssue #?(\d+)', '', '🦎 issue #42', 'matched\t1\n10\t2\n'),
        (r'PAF-[0-9]+', '', 'PAF-88', 'matched\t1\n'),
        (r'issues.*', r'#(\d+)', '雪🦎 issues #42 and #73', 'matched\t1\n11\t3\n19\t3\n'),
        (r'issue (\d+)', '', 'no issue number', 'matched\t0\n'),
        (r'(\uD83E\uDD8E)', '', '🦎', 'matched\t1\n0\t2\n'),
        (r'issue (\d+)', '', 'prefix\0issue 42', 'matched\t0\n'),
    ]
    for prefix in prefixes:
        for check, extract, message, expected in fixtures:
            for file, value in zip(inputs, (check, extract, message)):
                file.write_bytes(value.encode('utf-16-le'))
            output = subprocess.check_output(prefix + [str(binary)] + [str(file) for file in inputs], text=True, timeout=6)
            assert output == expected, (prefix, message, output, expected)
        inputs[0].write_bytes(r'(?<=#)(\d+)'.encode('utf-16-le'))
        invalid = subprocess.run(prefix + [str(binary)] + [str(file) for file in inputs], capture_output=True, timeout=6)
        assert invalid.returncode == 1 and invalid.stderr, 'ECMAScript lookbehind unexpectedly accepted'
        for check, extract, message, expected in [
            (r'issue #(\d+)', '', '🦎 issue #42', 'styles\tutf8\ncontext\t5\t7\nidentifier\t12\t2\n'),
            (r'issues.*', r'#(\d+)', '雪🦎 issues #42 and #73 done', 'styles\tutf8\ncontext\t8\t7\nidentifier\t15\t3\ncontext\t18\t5\nidentifier\t23\t3\ncontext\t26\t5\n'),
            (r'(雪)', '', '🦎雪', 'styles\tutf8\nidentifier\t4\t3\n'),
        ]:
            for file, value in zip(inputs, (check, extract, message)):
                file.write_bytes(value.encode('utf-16-le'))
            output = subprocess.check_output(prefix + [str(binary)] + [str(file) for file in inputs] + ['--styles-utf8'], text=True, timeout=6)
            assert output == expected, (prefix, message, output, expected)
        for check, message, expected in [
            (r'(foo)|(bar)', 'FOO bar foo', 'captures\tutf16\n0\t3\n4\t3\n8\t3\n'),
            (r'(after)', 'before\0after', 'captures\tutf16\n7\t5\n'),
            (r'(a\x00b)', 'a\0b', 'captures\tutf16\n0\t1\n'),
        ]:
            for file, value in zip(inputs, (check, '', message)):
                file.write_bytes(value.encode('utf-16-le'))
            output = subprocess.check_output(prefix + [str(binary)] + [str(file) for file in inputs] + ['--code-captures'], text=True, timeout=6)
            assert output == expected, (prefix, message, output, expected)
print('IssueRegex: universal macOS 13 matcher, UTF-16 offsets, extraction, source and system linkage verified.')
