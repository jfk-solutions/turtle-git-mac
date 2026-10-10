#!/usr/bin/env python3
"""Verify layout slices, SDK linkage, corresponding source and actual OGDF output."""
import argparse
import hashlib
import json
import math
import pathlib
import plistlib
import re
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('runtime', type=pathlib.Path)
    parser.add_argument('--all-architectures', action='store_true')
    args = parser.parse_args()
    runtime = args.runtime
    manifest = json.loads((runtime / 'provenance.json').read_text())
    pin = json.loads((ROOT / 'Configuration/GraphLayoutRuntime.json').read_text())
    assert manifest['pin'] == pin
    binary = runtime / 'graph-layout'
    assert digest(binary) == manifest['binary_sha256']
    for relative, expected in manifest['source_sha256'].items():
        assert digest(ROOT / relative) == expected, relative
        assert digest(runtime / 'Sources/build' / relative) == expected, relative
    for relative, expected in manifest['license_sha256'].items():
        assert digest(runtime / relative) == expected, relative
    assert digest(runtime / 'Sources/ogdf.tar.gz') == pin['ogdf']['sha256']
    assert digest(runtime / 'Sources/LICENSE_EPL_v1.html') == pin['coin_license']['sha256']
    archs = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()
    assert set(archs) == set(pin['architectures'])
    for architecture in archs:
        versions = subprocess.check_output(['xcrun', 'vtool', '-arch', architecture, '-show-build', str(binary)], text=True)
        assert re.findall(r'\bminos\s+([0-9.]+)', versions) == [pin['deployment_target']]
        links = subprocess.check_output(['otool', '-arch', architecture, '-L', str(binary)], text=True)
        for line in links.splitlines()[1:]:
            path = line.strip().split(' ', 1)[0]
            assert path.startswith(('/usr/lib/', '/System/Library/')), path
    if manifest.get('signed'):
        subprocess.run(['codesign', '--verify', '--strict', str(binary)], check=True)
        assert re.fullmatch(r'[0-9a-f]{64}', manifest['unsigned_binary_sha256'])
        if manifest.get('sandbox_inherited'):
            display = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(binary)], capture_output=True, check=True)
            entitlements = plistlib.loads(display.stdout)
            assert entitlements.get('com.apple.security.app-sandbox') is True
            assert entitlements.get('com.apple.security.inherit') is True
            # The identical unsigned helper was exercised before embedding.
            # An inherited-sandbox helper requires its signed app parent; this
            # command's Python host cannot prove signed native invocation.
            print('GraphLayout: inherited-sandbox signature, source/license hashes, architectures and SDK linkage verified; signed app invocation remains pending.')
            return
    else:
        assert not manifest.get('sandbox_inherited')
    prefixes = [['arch', '-'+arch] for arch in pin['architectures']] if args.all_architectures else [[]]
    fixtures = [([], []), ([(120, 40)], []),
                ([(120, 40), (200, 60), (80, 30), (100, 40)], [(0, 1), (0, 2), (1, 3), (2, 3), (0, 3)]),
                ([(120, 40)] * 6, [(0, 1), (0, 2), (0, 3), (1, 4), (2, 4), (3, 4)])]
    with tempfile.TemporaryDirectory(prefix='turtlegit-graph-layout-') as directory:
        file = pathlib.Path(directory) / 'input'
        for prefix in prefixes:
            for sizes, edges in fixtures:
                raw = 'TGGRAPH1 '+str(len(sizes))+' '+str(len(edges))+'\n'
                raw += ''.join(str(w)+' '+str(h)+'\n' for w, h in sizes)
                raw += ''.join(str(a)+' '+str(b)+'\n' for a, b in edges)
                file.write_text(raw)
                result = subprocess.run(prefix+[str(binary), str(file)], capture_output=True, text=True, timeout=30, check=True)
                rows = result.stdout.splitlines()
                assert rows[0] == 'TGGRAPH1 '+str(len(sizes))+' '+str(len(edges))
                assert len(rows) == 1+len(sizes)+len(edges)
                centers = [tuple(map(float, row.split())) for row in rows[1:1+len(sizes)]]
                assert all(len(point) == 2 and all(math.isfinite(v) for v in point) for point in centers)
                for i, (x, y) in enumerate(centers):
                    w, h = sizes[i]
                    assert x >= w/2 and y >= h/2
                    for j in range(i):
                        ox, oy = centers[j]; ow, oh = sizes[j]
                        assert abs(x-ox) >= (w+ow)/2-1e-7 or abs(y-oy) >= (h+oh)/2-1e-7, 'Overlapping node rectangles'
                for (a, b), row in zip(edges, rows[1+len(sizes):]):
                    values = row.split(); count = int(values[0])
                    assert len(values) == 1+2*count
                    assert all(math.isfinite(float(v)) for v in values[1:])
                    assert centers[b][1] > centers[a][1], 'Parent must be below child'
                assert file.read_text() == raw
            for raw in ['BAD 0 0\n', 'TGGRAPH1 1 0\n-1 40\n', 'TGGRAPH1 1 1\n10 10\n0 0\n',
                        'TGGRAPH1 2 2\n10 10\n10 10\n0 1\n1 0\n', 'TGGRAPH1 0 0\nextra\n']:
                file.write_text(raw)
                result = subprocess.run(prefix+[str(binary), str(file)], capture_output=True, text=True, timeout=30)
                assert result.returncode != 0 and result.stderr and not result.stdout
    print('GraphLayout: universal macOS 13, SDK-only linkage, pinned OGDF/COIN source/licenses and actual graph geometry verified.')


if __name__ == '__main__':
    main()
