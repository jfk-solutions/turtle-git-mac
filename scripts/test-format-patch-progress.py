#!/usr/bin/env python3
"""Cached owned Format Patch native checks linked to the current Debug application."""
import argparse
import ast
import hashlib
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--receiver', type=Path, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
engines = args.git or [Path('/usr/bin/git')]
fixtures = args.receiver or [Path('docs/qa/format-patch-progress-native-2026-10-08.swift')]
for git in engines:
    if not git.is_file() or not os.access(git, os.X_OK): parser.error('Git executable unavailable: ' + str(git))
products = root / 'build/Build/Products/Debug'
objects = sorted((root / 'build/Build/Intermediates.noindex/TurtleGitMac.build/Debug/TurtleGitMac.build/Objects-normal' / platform.machine()).glob('*.o'))
if not objects or not (products / 'TurtleGitMac.swiftmodule').exists(): raise SystemExit('Build TurtleGitMac Debug first.')
driver = ast.parse((root / 'scripts/test-synchronization-dialog.py').read_text())
helper = next(n for n in driver.body if isinstance(n, ast.FunctionDef) and n.name == 'close_receiver')
cleanup = {'os': os, 'signal': signal, 'time': time, 'subprocess': subprocess}
exec(compile(ast.Module(body=[helper], type_ignores=[]), '<owned receiver cleanup>', 'exec'), cleanup)
with tempfile.TemporaryDirectory(prefix='TurtleGitFormatPatchNative-') as temporary:
    directory = Path(temporary)
    sources, entries = [], []
    for index, fixture in enumerate(fixtures):
        text = (root / fixture).read_text()
        entry = re.search(r'@main struct (\w+)', text)
        if not entry: parser.error('Missing receiver entry: ' + str(fixture))
        entries.append(entry.group(1))
        source = directory / ('Fixture' + str(index) + '.swift')
        source.write_text('@testable import TurtleGitMac\n' + text.replace('@main struct', 'struct', 1))
        sources.append(source)
    main = directory / 'Main.swift'
    branches = '\n'.join('case "' + str(index) + '": try await ' + name + '.main()' for index, name in enumerate(entries))
    main.write_text('''import AppKit
@_cdecl("turtlegit_patch_batch_main") func bootstrap() -> Int32 {
    NSApplication.shared.setActivationPolicy(.prohibited)
    Task { @MainActor in
        do {
            switch CommandLine.arguments[3] {
''' + branches + r'''
            default: exit(2)
            }
            exit(0)
        } catch { fputs("Format Patch native QA failed: \(error)\n", stderr); exit(1) }
    }
    NSApplication.shared.run(); return 0
}
''')
    digest = hashlib.sha256()
    digest.update((platform.machine() + '/macos13/swift5/WMO-Onone/format-patch-v1').encode())
    digest.update(subprocess.check_output(['xcrun', 'swiftc', '--version']))
    inputs = [*objects, *sources, main]
    for imported in [products / 'TurtleGitMac.swiftmodule', products / 'TurtleGitCore.framework']:
        inputs += sorted(p for p in imported.rglob('*') if p.is_file() and not p.is_symlink())
    for source in inputs:
        digest.update(source.name.encode()); digest.update(source.read_bytes())
    cache = root / 'build/qa/native-receivers'; cache.mkdir(parents=True, exist_ok=True)
    executable = cache / ('format-patch-' + digest.hexdigest())
    if not executable.exists():
        staging = directory / 'receiver'
        subprocess.run(['xcrun', 'swiftc', '-whole-module-optimization', '-Onone', '-parse-as-library', '-swift-version', '5',
                        '-target', platform.machine() + '-apple-macos13.0', '-I', str(products), '-F', str(products),
                        *map(str, sources), str(main), *map(str, objects), '-framework', 'TurtleGitCore',
                        '-Xlinker', '-rpath', '-Xlinker', str(products), '-Xlinker', '-e', '-Xlinker', '_turtlegit_patch_batch_main',
                        '-o', str(staging)], cwd=root, check=True, timeout=300)
        staging.replace(executable)
        print('Format Patch receivers linked once to current Debug objects.', flush=True)
    else: print('Reusing Format Patch receiver for unchanged objects/modules/fixtures/toolchain.', flush=True)
    environment = os.environ.copy()
    environment.update(DYLD_FRAMEWORK_PATH=str(products), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
    for key in ['GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL']: environment.pop(key, None)
    for index, git in enumerate(engines):
        for case, fixture in enumerate(fixtures):
            data = directory / ('fixture-' + str(index) + '-' + str(case)); data.mkdir()
            print('Checking ' + str(fixture) + ' with ' + str(git), flush=True)
            command = [str(executable), str(data), str(git.absolute()), str(case)]
            receiver = subprocess.Popen(command, cwd=root, env=environment, start_new_session=True)
            try:
                code = receiver.wait(timeout=300)
                if code: raise subprocess.CalledProcessError(code, command)
            finally:
                cleanup['close_receiver'](receiver)
                print('Owned receiver reaped: ' + str(receiver.pid), flush=True)
