#!/usr/bin/env python3
"""Build a private, relocatable Perl/Subversion payload for the pinned Git.

All sources are verified before extraction. Installs stay in build/, never in
system or Homebrew prefixes. Component fingerprints permit interrupted builds
to resume without replacing a different toolchain's artifacts.
"""
import argparse
import hashlib
import inspect
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[1]

def run(arguments, cwd=None, env=None):
    print(' '.join(map(str, arguments)), flush=True)
    subprocess.run(list(map(str, arguments)), cwd=cwd, env=env, check=True)

def fetch(pin, cache):
    path = cache / pin['url'].rsplit('/', 1)[1]
    if not path.exists():
        part = path.with_suffix(path.suffix + '.download')
        try:
            with urllib.request.urlopen(pin['url'], timeout=60) as response, part.open('wb') as stream:
                shutil.copyfileobj(response, stream)
            if hashlib.new(pin['hash'], part.read_bytes()).hexdigest() != pin['digest']:
                raise RuntimeError('Downloaded source checksum mismatch: ' + path.name)
            part.replace(path)
        finally: part.unlink(missing_ok=True)
    if hashlib.new(pin['hash'], path.read_bytes()).hexdigest() != pin['digest']:
        raise RuntimeError('Cached source checksum mismatch: ' + path.name)
    return path

def extract(archive, folder):
    folder.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as stream:
        members = stream.getmembers(); roots = set()
        for entry in members:
            path = PurePosixPath(entry.name)
            if path.is_absolute() or '..' in path.parts or not path.parts:
                raise RuntimeError('Archive path escapes source tree')
            roots.add(path.parts[0])
            if not (entry.isfile() or entry.isdir() or entry.issym() or entry.islnk()):
                raise RuntimeError('Archive contains a special file')
            if entry.issym() or entry.islnk():
                target = PurePosixPath(entry.linkname)
                normalized = PurePosixPath(posixpath.normpath(str(path.parent / target) if entry.issym() else str(target)))
                if target.is_absolute() or normalized.parts[0] != path.parts[0]:
                    raise RuntimeError('Archive link escapes source tree')
        if len(roots) != 1: raise RuntimeError('Expected one source archive root')
        tree = folder / next(iter(roots))
        if not tree.exists(): stream.extractall(folder)
        return tree

def macho(path):
    return path.is_file() and not path.is_symlink() and path.read_bytes()[:4] in [b'\xfe\xed\xfa\xce', b'\xfe\xed\xfa\xcf', b'\xce\xfa\xed\xfe', b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe']

def relocate(folder):
    binaries = [p for p in folder.rglob('*') if macho(p)]
    libraries = {p.name: p for p in binaries if p.suffix == '.dylib'}
    for alias in folder.rglob('*.dylib'):
        if alias.is_symlink():
            resolved = alias.resolve()
            if not str(resolved).startswith(str(folder.resolve()) + '/') or not macho(resolved): raise RuntimeError('Invalid private library alias')
            libraries[alias.name] = resolved
    for path in binaries:
        dependencies = subprocess.check_output(['/usr/bin/otool', '-L', path], text=True).splitlines()[1:]
        for line in dependencies:
            old = line.strip().split(' (', 1)[0]
            if old.startswith(('/usr/lib/', '/System/Library/')): continue
            destination = libraries.get(Path(old).name)
            if destination == path:
                run(['/usr/bin/install_name_tool', '-id', '@rpath/' + path.name, path]); continue
            if destination is None: raise RuntimeError('Unbundled native dependency: ' + old)
            relative = os.path.relpath(destination, path.parent)
            run(['/usr/bin/install_name_tool', '-change', old, '@loader_path/' + relative, path])
        run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', path])

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/git-svn-runtime/GitSVN')
    parser.add_argument('--architectures', nargs='+', choices=['arm64', 'x86_64'])
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args(); output = args.output.resolve()
    if output.exists(): parser.error('Output exists; choose a new directory.')
    pin = json.loads((ROOT / 'Configuration/GitSVNRuntime.json').read_text())
    git_pin = json.loads((ROOT / pin['git_pin']).read_text())
    architectures = list(dict.fromkeys(args.architectures or pin['architectures']))
    cache = ROOT / 'build/git-svn-runtime/cache'; cache.mkdir(parents=True, exist_ok=True)
    archives = {name: fetch(item, cache) for name, item in pin['sources'].items()}
    git_archive = fetch({'url': git_pin['source_url'], 'hash': 'sha256', 'digest': git_pin['source_sha256']}, cache)
    wheel = fetch(pin['build_tools']['scons'], cache)
    tools = cache / ('scons-' + pin['build_tools']['scons']['version'])
    if not tools.exists():
        tools.mkdir()
        with zipfile.ZipFile(wheel) as stream:
            for name in stream.namelist():
                path = PurePosixPath(name)
                if path.is_absolute() or '..' in path.parts: raise RuntimeError('Build-tool wheel path escapes cache')
            stream.extractall(tools)
    sdk = subprocess.check_output(['/usr/bin/xcrun', '--show-sdk-path'], text=True).strip()
    compiler = subprocess.check_output(['/usr/bin/xcrun', '--find', 'clang'], text=True).strip()
    inputs = {'pin': pin, 'git': git_pin, 'sdk': sdk, 'compiler': subprocess.check_output([compiler, '--version'], text=True), 'recipeVersion': 1}
    identity = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
    workspace = ROOT / 'build/git-svn-runtime/work' / identity
    work = []
    for arch in architectures:
        directory = workspace / arch; directory.mkdir(parents=True, exist_ok=True)
        stage = directory / 'prefix'; stage.mkdir(exist_ok=True)
        trees = {name: extract(archive, directory / 'sources' / name) for name, archive in archives.items()}
        git = extract(git_archive, directory / 'sources/git')
        env = dict(os.environ, PATH='/usr/bin:/bin:/usr/sbin:/sbin', MACOSX_DEPLOYMENT_TARGET=pin['minimum_macos'], SDKROOT=sdk)
        for key in ['CFLAGS', 'CPPFLAGS', 'LDFLAGS', 'LIBRARY_PATH', 'CPATH', 'PKG_CONFIG_PATH', 'PERL5LIB', 'PERL5OPT', 'PERLLIB', 'DYLD_LIBRARY_PATH', 'DYLD_FRAMEWORK_PATH']: env.pop(key, None)
        flags = '-O2 -arch ' + arch + ' -isysroot ' + sdk + ' -mmacosx-version-min=' + pin['minimum_macos']
        env.update(CC=compiler, CFLAGS=flags, CPPFLAGS='-isysroot ' + sdk, LDFLAGS=flags, PKG_CONFIG='/usr/bin/false')
        def component(name, build, extra=None):
            recipe = hashlib.sha256((inspect.getsource(build) + flags + json.dumps(extra, sort_keys=True)).encode()).hexdigest()
            stamp = directory / (name + '.complete')
            if not stamp.exists() or stamp.read_text().strip() != recipe: build(); stamp.write_text(recipe + '\n')
            else: print('Reusing completed ' + name + ' for ' + arch, flush=True)
        perl_prefix = stage / 'Perl'; perl = perl_prefix / 'bin/perl'
        def build_perl():
            # Reconfiguration must not reuse generated Perl headers/objects.
            # A plain make clean leaves enough old configuration to mix ABIs.
            shutil.rmtree(trees['perl'])
            trees['perl'] = extract(archives['perl'], directory / 'sources/perl')
            if perl_prefix.exists(): shutil.rmtree(perl_prefix)
            run(['/bin/sh', 'Configure', '-des', '-Dprefix=' + str(perl_prefix), '-Duserelocatableinc', '-Uuseshrplib', '-Dcc=' + compiler, '-Dccflags=' + flags, '-Dldflags=' + flags, '-Dlddlflags=-bundle -undefined dynamic_lookup ' + flags, '-Doptimize=-O2', '-Dman1dir=none', '-Dman3dir=none'], cwd=trees['perl'], env=env)
            run(['/usr/bin/make', '-j' + str(args.jobs)], cwd=trees['perl'], env=env)
            run(['/usr/bin/make', 'install'], cwd=trees['perl'], env=env)
        component('perl', build_perl)
        deps = stage / 'Dependencies'
        for name, options in [('apr', []), ('apr-util', ['--with-apr=' + str(deps), '--with-expat=' + sdk + '/usr', '--without-crypto'])]:
            def build_apr(name=name, options=options):
                run(['./configure', '--prefix=' + str(deps), '--enable-shared', '--enable-static', *options], cwd=trees[name], env=env)
                run(['/usr/bin/make', '-j' + str(args.jobs)], cwd=trees[name], env=env)
                run(['/usr/bin/make', 'install'], cwd=trees[name], env=env)
            component(name, build_apr, options)
        ssl = stage / 'OpenSSL'
        def build_ssl():
            target = 'darwin64-arm64-cc' if arch == 'arm64' else 'darwin64-x86_64-cc'
            run(['/usr/bin/perl', 'Configure', target, 'no-shared', 'no-module', 'no-dso', 'no-tests', 'no-autoload-config', '--prefix=' + str(ssl), '--openssldir=/etc/ssl', '-mmacosx-version-min=' + pin['minimum_macos']], cwd=trees['openssl'], env=env)
            run(['/usr/bin/make', '-j' + str(args.jobs), 'build_libs'], cwd=trees['openssl'], env=env)
            (ssl / 'lib').mkdir(parents=True, exist_ok=True)
            shutil.copytree(trees['openssl'] / 'include', ssl / 'include', dirs_exist_ok=True)
            for library in ['libssl.a', 'libcrypto.a']: shutil.copy2(trees['openssl'] / library, ssl / 'lib' / library)
        component('openssl', build_ssl)
        def build_serf():
            serf_env = dict(env, PYTHONPATH=str(tools))
            run([sys.executable, '-c', 'import SCons.Script; SCons.Script.main()', '-j' + str(args.jobs), 'PREFIX=' + str(deps), 'APR=' + str(deps / 'bin/apr-1-config'), 'APU=' + str(deps / 'bin/apu-1-config'), 'OPENSSL=' + str(ssl), 'CC=' + compiler, 'CFLAGS=' + flags, 'LINKFLAGS=' + flags, 'install'], cwd=trees['serf'], env=serf_env)
        component('serf', build_serf)
        svn = stage / 'Subversion'
        def build_svn():
            svn_env = dict(env, PATH=str(perl_prefix / 'bin') + ':' + env['PATH'])
            run(['./configure', '--prefix=' + str(svn), '--with-apr=' + str(deps), '--with-apr-util=' + str(deps), '--with-serf=' + str(deps), '--with-sqlite=' + sdk + '/usr', '--with-perl5=' + str(perl), '--with-lz4=internal', '--with-utf8proc=internal', '--without-apxs', '--without-berkeley-db', '--without-swig', '--without-gpg-agent', '--without-gnome-keyring', '--without-kwallet', '--without-jdk', '--disable-nls', '--disable-static'], cwd=trees['subversion'], env=svn_env)
            run(['/usr/bin/make', '-j' + str(args.jobs)], cwd=trees['subversion'], env=svn_env)
            run(['/usr/bin/make', 'install'], cwd=trees['subversion'], env=svn_env)
            run(['/usr/bin/make', '-j' + str(args.jobs), 'LDFLAGS=' + flags + ' -Wl,-undefined,dynamic_lookup', 'LDDLFLAGS=-bundle -undefined dynamic_lookup ' + flags, 'swig-pl'], cwd=trees['subversion'], env=svn_env)
            run(['/usr/bin/make', 'LDFLAGS=' + flags + ' -Wl,-undefined,dynamic_lookup', 'LDDLFLAGS=-bundle -undefined dynamic_lookup ' + flags, 'install-swig-pl'], cwd=trees['subversion'], env=svn_env)
        component('subversion', build_svn)
        binding_root = svn / 'lib/perl5/site_perl'
        if not binding_root.is_dir(): raise RuntimeError('Subversion did not install its Perl bindings')
        installed_bindings = perl_prefix / 'lib/perl5/site_perl'
        if installed_bindings.exists(): shutil.rmtree(installed_bindings)
        shutil.copytree(binding_root, installed_bindings)
        modules = stage / 'GitPerl'; modules.mkdir(exist_ok=True)
        for source in (git / 'perl').rglob('*.pm'):
            destination = modules / source.relative_to(git / 'perl'); destination.parent.mkdir(parents=True, exist_ok=True)
            text = source.read_text().replace('@@NO_GETTEXT@@', 'YesPlease').replace('@@NO_PERL_CPAN_FALLBACKS@@', '').replace('@@LOCALEDIR@@', '').replace('@NO_GETTEXT@', 'YesPlease').replace('@NO_PERL_CPAN_FALLBACKS@', '').replace('@LOCALEDIR@', '')
            destination.write_text(text)
        text = (git / 'git-svn.perl').read_text().replace('@@GIT_VERSION@@', git_pin['version']).replace('@GIT_VERSION@', git_pin['version'])
        adapter = "BEGIN { if (defined $ENV{TURTLEGIT_SVN_CONFIG_DIR}) { $Git::SVN::Ra::config_dir = $ENV{TURTLEGIT_SVN_CONFIG_DIR}; } }\n"
        (modules / 'git-svn.perl').write_text(adapter + text)
        work.append((arch, stage, trees, git))
    prepared = output.parent / ('.git-svn-stage-' + str(uuid.uuid4())); prepared.mkdir(parents=True)
    try:
        core = prepared / 'libexec/git-core'; core.mkdir(parents=True)
        payload = prepared / 'libexec/git-svn-runtime'; payload.mkdir()
        for arch, stage, _, _ in work:
            destination = payload / arch; shutil.copytree(stage, destination, symlinks=True)
            shutil.rmtree(destination / 'Subversion/lib/perl5/site_perl')
            relocate(destination)
        flags = [item for arch in architectures for item in ['-arch', arch]]
        run([compiler, *flags, '-isysroot', sdk, '-mmacosx-version-min=' + pin['minimum_macos'], '-O2', '-DTURTLEGIT_PERL_VERSION="'+pin['sources']['perl']['version']+'"', ROOT / 'Sources/GitSVNLauncher/main.c', '-o', core / 'git-svn'])
        licenses = prepared / 'share/licenses/git-svn'; licenses.mkdir(parents=True)
        for name, archive in archives.items(): shutil.copy2(archive, licenses / archive.name)
        shutil.copy2(git_archive, licenses / git_archive.name)
        shutil.copy2(work[0][3] / 'COPYING', licenses / 'Git-COPYING')
        for name, tree in work[0][2].items():
            notices = licenses / name; notices.mkdir()
            for filename in ['LICENSE', 'LICENSE.txt', 'NOTICE', 'COPYING', 'Artistic']:
                if (tree / filename).is_file(): shutil.copy2(tree / filename, notices / filename)
        reconstruction = licenses / 'build'; (reconstruction / 'scripts').mkdir(parents=True)
        (reconstruction / 'Configuration').mkdir(); (reconstruction / 'Sources/GitSVNLauncher').mkdir(parents=True)
        shutil.copy2(__file__, reconstruction / 'scripts/build-git-svn-runtime.py')
        for name in ['validate-git-svn-runtime.py', 'validate_git_svn_support.py', 'validate-git-runtime.py', 'git_lfs_runtime.py', 'runtime_bundle_layout.py']:
            shutil.copy2(ROOT / 'scripts' / name, reconstruction / 'scripts' / name)
        for name in ['GitSVNRuntime.json', 'GitRuntime.json']: shutil.copy2(ROOT / 'Configuration' / name, reconstruction / 'Configuration' / name)
        shutil.copy2(ROOT / 'Sources/GitSVNLauncher/main.c', reconstruction / 'Sources/GitSVNLauncher/main.c')
        manifest = {'pin': pin, 'git': git_pin, 'architectures': architectures, 'buildInputs': inputs, 'signed': False,
            'status': 'built; validation, embedding and signed acceptance pending',
            'files_sha256': {str(p.relative_to(prepared)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(prepared.rglob('*')) if p.is_file() and not p.is_symlink()}}
        (prepared / 'runtime-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        prepared.replace(output)
    finally:
        if prepared.exists(): shutil.rmtree(prepared)
    print('Built Git SVN runtime: ' + str(output), flush=True)

if __name__ == '__main__': main()
