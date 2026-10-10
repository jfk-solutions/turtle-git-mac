#!/usr/bin/env python3
"""Build TortoiseGit's pinned OGDF/COIN with a universal graph layout adapter."""
import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess
import tarfile
import urllib.request
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=pathlib.Path, default=ROOT / 'build/graph-layout-runtime/GraphLayout')
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and not (output / 'provenance.json').is_file():
        raise RuntimeError('Refusing to replace an unrecognized GraphLayout directory')
    pin = json.loads((ROOT / 'Configuration/GraphLayoutRuntime.json').read_text())
    cache = ROOT / 'build/graph-layout-runtime/cache'
    cache.mkdir(parents=True, exist_ok=True)
    inputs = {}
    for name, filename in [('ogdf', 'ogdf-' + pin['ogdf']['commit'] + '.tar.gz'), ('coin_license', 'epl-v10.html')]:
        path = cache / filename
        if not path.is_file():
            bundled = ROOT.parent / ('ogdf.tar.gz' if name == 'ogdf' else 'LICENSE_EPL_v1.html')
            if bundled.is_file():
                shutil.copy2(bundled, path)
            else:
                with urllib.request.urlopen(pin[name]['url'], timeout=60) as response:
                    path.write_bytes(response.read())
        if digest(path) != pin[name]['sha256']:
            raise RuntimeError('Pinned input checksum mismatch: ' + name)
        inputs[name] = path
    work = ROOT / 'build/graph-layout-runtime/work'
    source = work / ('ogdf-' + pin['ogdf']['commit'])
    source.mkdir(parents=True, exist_ok=True)
    with tarfile.open(inputs['ogdf']) as archive:
        for member in archive.getmembers():
            destination = source.joinpath(*pathlib.PurePosixPath(member.name).parts[1:])
            if not destination.resolve().is_relative_to(source.resolve()):
                raise RuntimeError('Source archive path escapes extraction directory')
            if member.isdir():
                destination.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                destination.parent.mkdir(parents=True, exist_ok=True)
                contents = archive.extractfile(member).read()
                if not destination.is_file() or destination.read_bytes() != contents:
                    destination.write_bytes(contents)
            else:
                raise RuntimeError('Unsupported source archive entry')
    build = work / 'universal-release'
    subprocess.run(['cmake', '-S', str(source), '-B', str(build), '-DCMAKE_BUILD_TYPE=Release',
                    '-DCMAKE_OSX_ARCHITECTURES=' + ';'.join(pin['architectures']),
                    '-DCMAKE_OSX_DEPLOYMENT_TARGET=' + pin['deployment_target'],
                    '-DBUILD_SHARED_LIBS=OFF', '-DCOIN_LIBRARY_TYPE=STATIC'], check=True)
    subprocess.run(['cmake', '--build', str(build), '--target', 'OGDF', '--parallel', '4'], check=True)
    binary = work / 'graph-layout'
    adapter = ROOT / 'Sources/TurtleGitGraphLayout/main.cpp'
    architectures = [flag for arch in pin['architectures'] for flag in ['-arch', arch]]
    subprocess.run(['xcrun', 'clang++', '-std=c++17', '-O2', '-DNDEBUG', *architectures,
                    '-mmacosx-version-min=' + pin['deployment_target'],
                    '-I' + str(source / 'include'), '-I' + str(source / 'include/coin'),
                    '-I' + str(build / 'include/ogdf-release'), str(adapter),
                    str(build / 'libOGDF.a'), str(build / 'libCOIN.a'), '-o', str(binary)], check=True)
    stage = output.with_name(output.name + '-staging-' + uuid.uuid4().hex)
    stage.mkdir(parents=True)
    try:
        shutil.copy2(binary, stage / 'graph-layout')
        shutil.copy2(ROOT / 'LICENSE', stage / 'LICENSE')
        for name in ['LICENSE.txt', 'LICENSE_GPL_v2.txt', 'LICENSE_GPL_v3.txt']:
            shutil.copy2(source / name, stage / name)
        shutil.copy2(inputs['coin_license'], stage / 'LICENSE_EPL_v1.html')
        reconstruction = stage / 'Sources/build'
        reconstruction.mkdir(parents=True)
        shutil.copy2(inputs['ogdf'], stage / 'Sources/ogdf.tar.gz')
        shutil.copy2(inputs['coin_license'], stage / 'Sources/LICENSE_EPL_v1.html')
        files = ['LICENSE', 'Configuration/GraphLayoutRuntime.json', 'Sources/TurtleGitGraphLayout/main.cpp',
                 'scripts/build-graph-layout-runtime.py', 'scripts/validate-graph-layout-runtime.py',
                 'scripts/embed-graph-layout-runtime.py']
        for relative in files:
            destination = reconstruction / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, destination)
        (stage / 'provenance.json').write_text(json.dumps({
            'pin': pin, 'binary_sha256': digest(stage / 'graph-layout'),
            'source_sha256': {relative: digest(ROOT / relative) for relative in files},
            'license_sha256': {name: digest(stage / name) for name in ['LICENSE', 'LICENSE.txt', 'LICENSE_GPL_v2.txt', 'LICENSE_GPL_v3.txt', 'LICENSE_EPL_v1.html']},
            'layout': {'ranking': 'OptimalRanking', 'cross_minimization': 'MedianHeuristic',
                       'hierarchy': 'FastHierarchyLayout', 'layer_distance': 30, 'node_distance': 25},
            'signed': False}, indent=2) + '\n')
        subprocess.run(['python3', str(ROOT / 'scripts/validate-graph-layout-runtime.py'), str(stage)], check=True)
        if output.exists():
            shutil.rmtree(output)
        stage.rename(output)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    print('Built verified universal GraphLayout: ' + str(output))


if __name__ == '__main__':
    main()
