#!/usr/bin/env python3
"""Build the pinned official parser and static PCRE2 for both macOS architectures."""
import argparse
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import tarfile
import urllib.request
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]


def run(args):
    subprocess.run([str(arg) for arg in args], check=True)


def extract(archive, destination):
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as source:
        for entry in source.getmembers():
            target = destination.joinpath(*pathlib.Path(entry.name).parts[1:])
            if not target.resolve().is_relative_to(destination.resolve()):
                raise RuntimeError('Archive path escapes source directory')
            if entry.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif entry.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(source.extractfile(entry).read())
            else:
                raise RuntimeError('Source archive contains a link or special file')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=pathlib.Path, default=ROOT / 'build/editorconfig-runtime/EditorConfig')
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and not (output / 'provenance.json').is_file():
        raise RuntimeError('Refusing to replace a directory without a runtime provenance manifest')
    pin = json.loads((ROOT / 'Configuration/EditorConfigRuntime.json').read_text())
    cache = ROOT / 'build/editorconfig-runtime/cache'
    cache.mkdir(parents=True, exist_ok=True)
    archives = {}
    for name in ['pcre2', 'editorconfig', 'core_tests']:
        item = pin[name]
        archive = cache / (name + '-' + item['sha256'] + '.tar.gz')
        if not archive.exists():
            bundled = ROOT.parent / (name + '.tar.gz') if ROOT.name == 'build' and ROOT.parent.name == 'Sources' else None
            if bundled is not None and bundled.is_file():
                shutil.copy2(bundled, archive)
            else:
                archive.write_bytes(urllib.request.urlopen(item['url']).read())
        if hashlib.sha256(archive.read_bytes()).hexdigest() != item['sha256']:
            raise RuntimeError('Source checksum mismatch: ' + name)
        archives[name] = archive
    workspace = ROOT / 'build/editorconfig-runtime/work'
    workspace.mkdir(parents=True, exist_ok=True)
    pcre = workspace / ('pcre2-' + pin['pcre2']['version'])
    editor = workspace / ('editorconfig-' + pin['editorconfig']['version'])
    extract(archives['pcre2'], pcre)
    extract(archives['editorconfig'], editor)
    extract(archives['core_tests'], editor / 'tests')
    common = ['-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_OSX_ARCHITECTURES=' + ';'.join(pin['architectures']),
              '-DCMAKE_OSX_DEPLOYMENT_TARGET=' + pin['deployment_target']]
    pcre_build = workspace / 'pcre-build'
    run(['cmake', '-S', pcre, '-B', pcre_build, *common, '-DBUILD_SHARED_LIBS=OFF',
         '-DPCRE2_BUILD_PCRE2_8=ON', '-DPCRE2_BUILD_PCRE2_16=OFF', '-DPCRE2_BUILD_PCRE2_32=OFF',
         '-DPCRE2_SUPPORT_JIT=OFF', '-DPCRE2_BUILD_TESTS=OFF', '-DPCRE2_BUILD_PCRE2GREP=OFF'])
    run(['cmake', '--build', pcre_build, '--target', 'pcre2-8-static', '--parallel', '4'])
    pcre_library = pcre_build / 'libpcre2-8.a'
    editor_build = workspace / 'editor-build'
    run(['cmake', '-S', editor, '-B', editor_build, *common, '-DPCRE2_INCLUDE_DIR=' + str(pcre_build / 'interface'),
         '-DPCRE2_LIBRARY_RELEASE=' + str(pcre_library), '-DPCRE2_LIBRARY_DEBUG=' + str(pcre_library), '-DPCRE2_STATIC=ON'])
    run(['cmake', '--build', editor_build, '--target', 'editorconfig_static', '--parallel', '4'])
    binary = editor_build / 'bin/editorconfig'
    binary.parent.mkdir(parents=True, exist_ok=True)
    architectures = [flag for arch in pin['architectures'] for flag in ['-arch', arch]]
    # Upstream's fully-static executable option also passes Linux's -static on
    # Darwin. Link its unchanged CLI against static archives and the system SDK.
    run(['xcrun', 'clang', *architectures, '-mmacosx-version-min=' + pin['deployment_target'], '-O2',
         '-I' + str(editor / 'include'), '-I' + str(editor_build / 'src/auto'), editor / 'src/bin/main.c',
         editor_build / 'lib/libeditorconfig_static.a', pcre_library, '-o', binary])
    # Some upstream CTest wrappers resolve the versioned CMake target name;
    # direct tests use the unversioned CLI path. Supply the identical binary.
    shutil.copy2(binary, binary.with_name('editorconfig-' + pin['editorconfig']['version']))
    run(['ctest', '--test-dir', editor_build, '--output-on-failure'])
    archs = set(subprocess.check_output(['lipo', '-archs', binary], text=True).split())
    if archs != set(pin['architectures']):
        raise RuntimeError('EditorConfig architecture mismatch')
    build_versions = subprocess.check_output(['xcrun', 'vtool', '-show-build', binary], text=True)
    minimums = re.findall(r'\bminos\s+([0-9.]+)', build_versions)
    if len(minimums) != len(archs) or set(minimums) != {pin['deployment_target']}:
        raise RuntimeError('EditorConfig deployment target mismatch')
    linkage = subprocess.check_output(['otool', '-L', binary], text=True)
    for line in linkage.splitlines()[1:]:
        if not line.startswith('\t'):
            continue  # Universal binaries have a separate heading per slice.
        dependency = line.strip().split(' (')[0]
        if not dependency.startswith(('/usr/lib/', '/System/Library/')):
            raise RuntimeError('Non-system dynamic dependency: ' + dependency)
    run([binary, '--version'])
    prepared = output.with_name(output.name + '.prepared-' + uuid.uuid4().hex)
    prepared.mkdir(parents=True)
    shutil.copy2(binary, prepared / 'editorconfig')
    licenses = prepared / 'Licenses'
    sources = prepared / 'Sources'
    licenses.mkdir(); sources.mkdir()
    shutil.copy2(editor / 'LICENSE', licenses / 'EditorConfig-LICENSE.txt')
    shutil.copy2(pcre / 'LICENCE.md', licenses / 'PCRE2-LICENSE.txt')
    for name, archive in archives.items():
        shutil.copy2(archive, sources / (name + '.tar.gz'))
    reconstruction = sources / 'build'
    (reconstruction / 'Configuration').mkdir(parents=True)
    (reconstruction / 'scripts').mkdir()
    shutil.copy2(ROOT / 'Configuration/EditorConfigRuntime.json', reconstruction / 'Configuration/EditorConfigRuntime.json')
    shutil.copy2(__file__, reconstruction / 'scripts/build-editorconfig-runtime.py')
    (sources / 'README.txt').write_text('Unmodified pinned source archives and reconstruction script.\nRun: python3 build/scripts/build-editorconfig-runtime.py\nRequires the macOS SDK, CMake and Python 3.9 or later.\n')
    (prepared / 'provenance.json').write_text(json.dumps({'pins': pin, 'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                                                       'architectures': sorted(archs), 'build_versions': build_versions, 'system_linkage': linkage}, indent=2) + '\n')
    if output.exists():
        shutil.rmtree(output)
    prepared.rename(output)
    print(output)


if __name__ == '__main__':
    main()
