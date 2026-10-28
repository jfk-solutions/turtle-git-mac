#!/usr/bin/env python3
"""Reconstruct the pinned metafile renderer and universal system-framework helper."""
import argparse
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import struct
import tarfile
import tempfile
import uuid
from pinned_download import download_verified

ROOT = pathlib.Path(__file__).resolve().parents[1]
SWIFT_SOURCES = ['Sources/TurtleGitMetafile/main.swift',
                 'Sources/TurtleGitMetafile/SpatialImageEffects.swift',
                 'Sources/TurtleGitMetafile/RedEyeImageEffect.swift',
                 'Sources/TurtleGitMetafile/SpatialImageSampling.swift']
FILES = ['LICENSE', 'Licenses/Wine-LGPL-2.1.txt', 'Licenses/BaseHmiTypes-MIT.txt', 'NOTICE', 'Configuration/MetafileRuntime.json', *SWIFT_SOURCES,
         'patches/metafile-renderer.patch', 'scripts/build-metafile-runtime.py',
         'scripts/validate-metafile-runtime.py', 'scripts/embed-metafile-runtime.py',
         'scripts/pinned_download.py', 'scripts/runtime_bundle_layout.py', 'scripts/git_lfs_runtime.py',
         'Sources/TurtleGitMetafile/Resources/color-curves.bin',
         'Sources/TurtleGitMetafile/Resources/color-curves.json', 'scripts/build-metafile-curve-data.py',
         'docs/qa/metafile-pointwise-effects-reference-2026-10-27/CurveLookupReference.cpp',
         'docs/qa/metafile-pointwise-effects-reference-2026-10-27/PointwiseEffectsReference.cpp']

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def bundle(source):
    """Bundle only reachable, static, relative CommonJS imports. No npm or eval loader."""
    modules = {}
    pattern = re.compile(r'''\brequire\(\s*(['"])([^'"]+)\1\s*\)''')
    def visit(relative):
        if relative in modules:
            return
        path = source / relative
        if not path.resolve().is_relative_to(source.resolve()) or path.suffix != '.js':
            raise RuntimeError('Module escapes reviewed source: ' + relative)
        text = path.read_text()
        modules[relative] = None
        dependencies = {}
        for match in pattern.finditer(text):
            name = match[2]
            if not name.startswith('.'):
                raise RuntimeError('External renderer module: ' + name)
            target = (path.parent / name).with_suffix('.js').resolve()
            key = str(target.relative_to(source.resolve()))
            dependencies[name] = key
            visit(key)
        # A future dynamic import must fail reconstruction rather than access host files.
        if len(re.findall(r'\brequire\s*\(', text)) != len(list(pattern.finditer(text))):
            raise RuntimeError('Dynamic CommonJS import in ' + relative)
        modules[relative] = (text, dependencies)
    entry = 'packages/wmf-emf-renderer/entry.js'
    visit(entry)
    lines = ['// Pinned WmfEmfViewer (MIT) with Wine hatch cells (LGPL-2.1-or-later); see LICENSE-renderer, LICENSE-Wine-hatches and provenance.json.', '(function(){"use strict";const definitions={};']
    for name, (text, dependencies) in sorted(modules.items()):
        lines += ['definitions[' + json.dumps(name) + ']=[function(require,module,exports){\n' + text + '\n},' + json.dumps(dependencies, sort_keys=True) + '];']
    lines += ['const cache={};function load(id){if(cache[id])return cache[id].exports;const d=definitions[id];if(!d)throw Error("Unknown bundled module");const m={exports:{}};cache[id]=m;d[0](name=>{if(!Object.hasOwn(d[1],name))throw Error("Unknown import");return load(d[1][name]);},m,m.exports);return m.exports;}',
              'globalThis.TurtleGitMetafile=load(' + json.dumps(entry) + ');})();\n']
    return '\n'.join(lines)

def extract(archive, destination):
    with tarfile.open(archive) as stream:
        for member in stream:
            relative = pathlib.PurePosixPath(*pathlib.PurePosixPath(member.name).parts[1:])
            target = destination / relative
            if not target.resolve().is_relative_to(destination.resolve()):
                raise RuntimeError('Escaping source archive')
            if member.isdir(): target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(stream.extractfile(member).read())
            else: raise RuntimeError('Unsupported source archive entry: ' + member.name)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=pathlib.Path, default=ROOT / 'build/metafile-runtime/Metafile')
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and not (output / 'provenance.json').is_file():
        raise RuntimeError('Refusing to replace unrecognized runtime')
    pin = json.loads((ROOT / 'Configuration/MetafileRuntime.json').read_text())
    curves = pin['image_effects']['curve_lookup']
    curve_data = ROOT / 'Sources/TurtleGitMetafile/Resources/color-curves.bin'
    if curve_data.stat().st_size != 598032 or digest(curve_data) != curves['sha256']:
        raise RuntimeError('Complete native curve domain resource does not match its pin')
    if curve_data.read_bytes()[:16] != b'TGCCLUT1' + struct.pack('<II', 2336, 256):
        raise RuntimeError('Invalid complete native curve domain header')
    cache = ROOT / 'build/metafile-runtime/cache'
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / ('renderer-' + pin['renderer']['commit'] + '.tar.gz')
    bundled_archive = ROOT.parent / 'renderer.tar.gz'
    if not archive.exists() and bundled_archive.is_file():
        if digest(bundled_archive) != pin['renderer']['sha256']:
            raise RuntimeError('Bundled renderer source checksum mismatch')
        shutil.copy2(bundled_archive, archive)
    download_verified(pin['renderer']['url'], archive, pin['renderer']['sha256'])
    compiler = subprocess.check_output(['xcrun', 'swiftc', '--version'], text=True)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    sdk_version = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], text=True).strip()
    hashes = {name: digest(ROOT / name) for name in FILES}
    flags = ['-O', '-whole-module-optimization', '-liconv', '-framework', 'JavaScriptCore', '-framework', 'CoreText', '-framework', 'ImageIO', '-framework', 'AppKit']
    key = hashlib.sha256(json.dumps([pin, hashes, compiler, sdk_version, flags], sort_keys=True).encode()).hexdigest()
    work = cache / key
    work.mkdir(exist_ok=True)
    binary = work / 'metafile-convert'
    renderer = work / 'renderer.js'
    if not binary.is_file() or not renderer.is_file():
        with tempfile.TemporaryDirectory(prefix='metafile-source-', dir=cache) as directory:
            source = pathlib.Path(directory)
            extract(archive, source)
            subprocess.run(['/usr/bin/patch', '-f', '-F', '0', '-p1', '-i', str(ROOT / 'patches/metafile-renderer.patch')], cwd=source, check=True)
            renderer.write_text(bundle(source))
            shutil.copy2(source / 'LICENSE', work / 'LICENSE-renderer')
        slices = []
        for arch in pin['architectures']:
            part = work / ('metafile-convert-' + arch)
            subprocess.run(['xcrun', 'swiftc', *flags, '-sdk', sdk,
                            '-target', arch + '-apple-macosx' + pin['deployment_target'],
                            *[str(ROOT / name) for name in SWIFT_SOURCES], '-o', str(part)], check=True)
            slices.append(str(part))
        subprocess.run(['lipo', '-create', *slices, '-output', str(binary)], check=True)
    stage = output.with_name(output.name + '-stage-' + uuid.uuid4().hex)
    stage.mkdir(parents=True)
    try:
        for name in ['metafile-convert', 'renderer.js', 'LICENSE-renderer']:
            shutil.copy2(work / name, stage / name)
        shutil.copy2(curve_data, stage / 'color-curves.bin')
        shutil.copy2(ROOT / 'Sources/TurtleGitMetafile/Resources/color-curves.json', stage / 'color-curves.json')
        shutil.copy2(ROOT / 'LICENSE', stage / 'LICENSE')
        shutil.copy2(ROOT / pin['hatch_patterns']['license_file'], stage / 'LICENSE-Wine-hatches')
        shutil.copy2(ROOT / pin['classic_clipping']['license_file'], stage / 'LICENSE-BaseHmiTypes')
        shutil.copy2(ROOT / 'NOTICE', stage / 'NOTICE')
        sources = stage / 'Sources/build'
        sources.mkdir(parents=True)
        shutil.copy2(archive, stage / 'Sources/renderer.tar.gz')
        for name in FILES:
            target = sources / name; target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, target)
        manifest = {'pin': pin, 'binary_sha256': digest(stage / 'metafile-convert'),
                    'renderer_sha256': digest(stage / 'renderer.js'), 'source_sha256': hashes,
                    'resource_sha256': {name: digest(stage / name) for name in ['color-curves.bin', 'color-curves.json']},
                    'license_sha256': {name: digest(stage / name) for name in ['LICENSE', 'LICENSE-renderer', 'LICENSE-Wine-hatches', 'LICENSE-BaseHmiTypes', 'NOTICE']},
                    'compiler': compiler, 'sdk_version': sdk_version, 'flags': flags, 'cache_key': key, 'signed': False}
        (stage / 'provenance.json').write_text(json.dumps(manifest, indent=2) + '\n')
        subprocess.run(['python3', str(ROOT / 'scripts/validate-metafile-runtime.py'), str(stage), '--structure-only'], check=True)
        if output.exists(): shutil.rmtree(output)
        stage.rename(output)
    finally:
        if stage.exists(): shutil.rmtree(stage)
    print('Built pinned universal Metafile runtime: ' + str(output))

if __name__ == '__main__': main()
