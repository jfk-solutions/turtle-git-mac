#!/usr/bin/env python3
"""Compile the standalone historical transport; run one owned bounded receiver."""
import argparse
import ast
import hashlib
import os
from pathlib import Path
import platform
import signal
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--scratch-path', type=Path, default=Path('.build'))
parser.add_argument('--skip-build', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
scratch = args.scratch_path.resolve()
build = ['swift', 'build', '-c', 'debug', '--scratch-path', str(scratch), '--target', 'TurtleGitCore']
if not args.skip_build:
    subprocess.run(build, cwd=root, check=True)
products = Path(subprocess.check_output(build + ['--show-bin-path'], cwd=root, text=True).strip())
# SwiftPM's native and Xcode backends expose different object/module layouts.
if (products / 'TurtleGitCore.o').is_file():
    objects = [products / 'TurtleGitCore.o', products / 'TurtleGitSMTP.o']
    module_path = products
else:
    objects = sorted((products / 'TurtleGitCore.build').glob('*.o')) + sorted((products / 'TurtleGitSMTP.build').glob('*.o'))
    module_path = products / 'Modules'
maps = [products / 'TurtleGitSMTP.build/module.modulemap']
maps += sorted(scratch.glob('**/GeneratedModuleMaps/TurtleGitSMTP.modulemap'))
module_map = next((p for p in maps if p.is_file()), None)
if not objects or not all(p.is_file() for p in objects) or module_map is None:
    raise SystemExit('Missing compiled Core/SMTP objects or module map; build the Core target first.')
sources = [root / 'Sources/TurtleGitMac/RepositoryBrowserDrag.swift', root / 'scripts/verify-browser-item-provider.swift']
flags = ['-parse-as-library', '-swift-version', '5', '-target', platform.machine() + '-apple-macos13.0',
         '-I', str(module_path), '-Xcc', '-fmodule-map-file=' + str(module_map), '-lcurl']
digest = hashlib.sha256()
digest.update(('provider-transport-v2/' + platform.machine() + '/macos13/swift5').encode())
digest.update(subprocess.check_output(['xcrun', 'swiftc', '--version']))
inputs = [*objects, *sources, module_map, root / 'Sources/TurtleGitSMTP/include/TurtleGitSMTP.h']
for path in [module_path / 'TurtleGitCore.swiftmodule', module_path / 'TurtleGitCore.swiftdoc']:
    if path.is_dir(): inputs += sorted(p for p in path.rglob('*') if p.is_file())
    elif path.is_file(): inputs.append(path)
for path in inputs:
    digest.update(path.name.encode()); digest.update(path.read_bytes())
cache = root / 'build/qa/native-receivers'; cache.mkdir(parents=True, exist_ok=True)
executable = cache / ('provider-' + digest.hexdigest())
with tempfile.TemporaryDirectory(prefix='TurtleGitProviderCompile-') as temporary:
    if not executable.exists():
        staging = Path(temporary) / 'check'
        subprocess.run(['xcrun', 'swiftc', *flags, *map(str, sources), *map(str, objects), '-o', str(staging)], cwd=root, check=True, timeout=300)
        staging.replace(executable)
        print('Standalone provider receiver compiled against Core only.', flush=True)
    else:
        print('Reusing provider receiver for unchanged transport/Core/modules/toolchain.', flush=True)
    environment = os.environ.copy()
    environment.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
    for key in ['GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL']:
        environment.pop(key, None)
    driver = ast.parse((root / 'scripts/test-synchronization-dialog.py').read_text())
    helper = next(n for n in driver.body if isinstance(n, ast.FunctionDef) and n.name == 'close_receiver')
    cleanup = {'os': os, 'signal': signal, 'time': time, 'subprocess': subprocess}
    exec(compile(ast.Module(body=[helper], type_ignores=[]), '<owned provider cleanup>', 'exec'), cleanup)
    receiver = subprocess.Popen([str(executable)], cwd=root, env=environment, start_new_session=True)
    try:
        code = receiver.wait(timeout=90)
        if code: raise subprocess.CalledProcessError(code, receiver.args)
    finally:
        cleanup['close_receiver'](receiver)
        print('Owned provider receiver reaped: ' + str(receiver.pid), flush=True)
