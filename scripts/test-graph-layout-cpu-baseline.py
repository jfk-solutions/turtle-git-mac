#!/usr/bin/env python3
"""Reproduce OGDF's Intel-host universal build failure and verify its build patch."""
import hashlib
import importlib.util
import json
import pathlib
import subprocess
import tarfile
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('graph_builder', ROOT / 'scripts/build-graph-layout-runtime.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)
pin = json.loads((ROOT / 'Configuration/GraphLayoutRuntime.json').read_text())
archive = ROOT / 'build/graph-layout-runtime/GraphLayout/Sources/ogdf.tar.gz'
assert hashlib.sha256(archive.read_bytes()).hexdigest() == pin['ogdf']['sha256']
with tarfile.open(archive) as package:
    members = [member for member in package.getmembers()
               if member.name.endswith('/cmake/compiler-specifics.cmake')]
    assert len(members) == 1
    original = package.extractfile(members[0]).read()

with tempfile.TemporaryDirectory(prefix='turtlegit-graph-cpu-') as temporary:
    root = pathlib.Path(temporary)
    for patched in [False, True]:
        source = root / ('patched' if patched else 'original')
        (source / 'cmake').mkdir(parents=True)
        (source / 'cmake/compiler-specifics.cmake').write_bytes(original)
        if patched:
            builder.patch_apple_cpu_baseline(source)
        # Exercise the exact upstream compiler configuration with an Intel
        # build-host processor, including when this test runs on Apple Silicon.
        (source / 'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.16)
project(OGDFCPURegression LANGUAGES CXX)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
include(cmake/compiler-specifics.cmake)
add_library(cpu-probe STATIC probe.cpp)
''')
        (source / 'probe.cpp').write_text('int cpu_probe() { return 42; }\n')
        build = source / 'build'
        configured = subprocess.run(['cmake', '-S', str(source), '-B', str(build),
            '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON',
            '-DCMAKE_OSX_ARCHITECTURES=' + ';'.join(pin['architectures']),
            '-DCMAKE_OSX_DEPLOYMENT_TARGET=' + pin['deployment_target']],
            capture_output=True, text=True, timeout=60)
        assert configured.returncode == 0, configured.stdout + configured.stderr
        commands = (build / 'compile_commands.json').read_text()
        assert ('-march=native' in commands) == (not patched), commands
        result = subprocess.run(['cmake', '--build', str(build)], capture_output=True,
                                text=True, timeout=60)
        if patched:
            assert result.returncode == 0, result.stdout + result.stderr
            slices = subprocess.check_output(['lipo', '-archs', str(build / 'libcpu-probe.a')], text=True)
            assert set(slices.split()) == set(pin['architectures']), slices
        else:
            assert result.returncode != 0, 'Original Intel-host flags unexpectedly compiled both slices'
            # Intel hosts reject native for arm64; Apple Silicon may instead
            # try to apply their Apple CPU to the x86_64 slice.
            assert any(message in result.stderr for message in
                       ["unsupported argument 'native'", 'unknown target CPU']), result.stderr
print('GraphLayout CPU baseline: original Intel-host failure reproduced; patched universal compilation passed.')
