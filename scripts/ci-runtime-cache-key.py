#!/usr/bin/env python3
"""Exact immutable helper cache keys, including captured transitive dependencies."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def key(name, toolchain, runner, root=ROOT):
    recipes = json.loads((root / 'Configuration/CIRuntimeCaches.json').read_text())
    recipe = recipes[name]
    digest = hashlib.sha256()
    for value in [name, toolchain, runner, json.dumps(recipe, sort_keys=True), (root / 'scripts/ci-runtime-cache-key.py').read_text()]:
        encoded = value.encode(); digest.update(len(encoded).to_bytes(8, 'big')); digest.update(encoded)
    for input_name in recipe['inputs']:
        path = Path(input_name)
        if path.is_absolute() or '..' in path.parts: raise ValueError('Cache input must stay in the workspace: ' + input_name)
        # Fail for missing transferred manifests/headers instead of producing an
        # empty dependency hash and reusing an incompatible helper payload.
        data = (root / path).read_bytes()
        encoded = input_name.encode(); digest.update(len(encoded).to_bytes(8, 'big')); digest.update(encoded)
        digest.update(len(data).to_bytes(8, 'big')); digest.update(data)
    return 'runtime-' + name + '-v1-' + digest.hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('runtime')
    parser.add_argument('--toolchain', required=True)
    parser.add_argument('--runner', required=True)
    args = parser.parse_args()
    print('key=' + key(args.runtime, args.toolchain, args.runner))

if __name__ == '__main__': main()
