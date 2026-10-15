#!/usr/bin/env python3
"""Run existing RefLog workflow fixtures with one cached link to Debug app objects."""
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

CASES = {
    'revision-handoffs': 'ReferenceLogRevisionHandoffsVerification',
    'comparisons': 'ReferenceLogComparisonsVerification',
    'ranges': 'ReferenceLogRangesVerification',
    'unified-diff': 'ReferenceLogUnifiedDiffVerification',
    'parent-comparisons': 'ReferenceLogParentComparisonsVerification',
    'history-actions': 'ReferenceLogHistoryActionsVerification',
    'remote-defaults': 'ReferenceLogRemoteDefaultsVerification',
    'express-switch': 'ReferenceLogExpressSwitchVerification',
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=CASES, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
cleanup_source = root / 'scripts/test-synchronization-dialog.py'
parsed = ast.parse(cleanup_source.read_text())
cleanup_function = next(n for n in parsed.body if isinstance(n, ast.FunctionDef) and n.name == 'close_receiver')
cleanup = {'os': os, 'signal': signal, 'time': time, 'subprocess': subprocess}
exec(compile(ast.Module(body=[cleanup_function], type_ignores=[]), '<owned receiver cleanup>', 'exec'), cleanup)
objects = sorted((root / 'build/Build/Intermediates.noindex/TurtleGitMac.build/Debug/TurtleGitMac.build/Objects-normal' / platform.machine()).glob('*.o'))
if not objects or not (products / 'TurtleGitMac.swiftmodule').exists():
    parser.error('Build TurtleGitMac Debug before running RefLog QA.')
# Preserve the packaged Git launcher spelling: GitRuntime uses its bin/Git
# location to supply GIT_EXEC_PATH and the other bundled helper directories.
engines = [git.absolute() for git in args.git or [Path('/usr/bin/git')]]
if not all(git.is_file() for git in engines):
    parser.error('Git executable does not exist.')

with tempfile.TemporaryDirectory(prefix='TurtleGitRefLogNativeBatch-') as temporary:
    folder = Path(temporary)
    fixtures = []
    # Compile every family once even for --only, so individual entry points
    # share the same cached receiver instead of rebuilding their own app copy.
    for case in CASES:
        source = root / ('docs/qa/reflog-' + case + '-native-2026-10-08.swift')
        fixture = folder / source.name
        text = source.read_text().replace('@main struct', 'struct', 1)
        text = text.replace('CommandLine.arguments[1]', 'ProcessInfo.processInfo.environment["TURTLEGIT_REFLOG_FIXTURE_ROOT"]!')
        fixture.write_text('@testable import TurtleGitMac\n' + text)
        fixtures.append(fixture)
    main = folder / 'Main.swift'
    calls = '\n'.join('        case "' + case + '": try await ' + name + '.main()' for case, name in CASES.items())
    main.write_text('''import AppKit
import TurtleGitCore

@MainActor enum RefLogBatch {
    static func run() async throws {
        let directory=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        for name in CommandLine.arguments.dropFirst(3) {
            let fixture=directory.appendingPathComponent(name,isDirectory:true)
            try FileManager.default.createDirectory(at:fixture,withIntermediateDirectories:true)
            setenv("TURTLEGIT_REFLOG_FIXTURE_ROOT",fixture.path,1)
            try Data(name.utf8).write(to:directory.appendingPathComponent("phase.txt"),options:.atomic)
            print("RefLog phase started: "+name);fflush(stdout)
            switch name {
''' + calls + '''
        default: throw CocoaError(.fileReadUnknown)
            }
            print("RefLog phase completed: "+name);fflush(stdout)
        }
    }
}
@_cdecl("turtlegit_reflog_batch_main") func bootstrap()->Int32 {
    NSApplication.shared.setActivationPolicy(.prohibited)
    Task { @MainActor in
        do {try await RefLogBatch.run();exit(0)}
        catch {fputs("RefLog batch failed: \\(error)\\n",stderr);exit(1)}
    }
    NSApplication.shared.run();return 0
}
''')
    flags = ['-whole-module-optimization', '-Onone', '-parse-as-library', '-swift-version', '5', '-target', platform.machine() + '-apple-macos13.0']
    digest = hashlib.sha256()
    digest.update(('reflog-app-objects-v1\0' + str(root) + '\0' + str(products) + '\0' + '\0'.join(flags)).encode())
    digest.update(subprocess.check_output(['xcrun', 'swiftc', '--version']))
    inputs = [Path(__file__), cleanup_source, *sorted((root / 'Sources/TurtleGitMac').glob('*.swift')), *objects, *fixtures, main]
    for imported in [products / 'TurtleGitCore.framework', products / 'TurtleGitMac.swiftmodule']:
        inputs += sorted(p for p in imported.rglob('*') if p.is_file() and not p.is_symlink())
    for source in inputs:
        digest.update(source.name.encode()); digest.update(source.read_bytes())
    cache = root / 'build/qa/native-receivers'; cache.mkdir(parents=True, exist_ok=True)
    executable = cache / ('reflog-' + digest.hexdigest())
    if not executable.exists():
        staging = folder / 'receiver'
        compile_started = time.monotonic()
        compiler = subprocess.Popen(['xcrun', 'swiftc', *flags, '-I', str(products), '-F', str(products),
            *map(str, fixtures), str(main), *map(str, objects), '-framework', 'TurtleGitCore',
            '-Xlinker', '-rpath', '-Xlinker', str(products), '-Xlinker', '-e', '-Xlinker', '_turtlegit_reflog_batch_main', '-o', str(staging)], cwd=root, start_new_session=True)
        try:
            try: code = compiler.wait(timeout=900)
            except subprocess.TimeoutExpired as error: raise RuntimeError('RefLog fixture compilation exceeded 900 seconds') from error
            if code: raise RuntimeError('RefLog fixture compilation exited ' + str(code))
        finally:
            cleanup['close_receiver'](compiler)
            print('Owned fixture compiler reaped: ' + str(compiler.pid), flush=True)
        staging.replace(executable)
        print('All eight RefLog fixtures linked once to existing Debug app objects in ' + format(time.monotonic() - compile_started, '.2f') + ' seconds.', flush=True)
    else:
        print('Reusing RefLog receiver for unchanged sources/objects/modules/fixtures/toolchain.', flush=True)
    environment = os.environ.copy()
    environment.update(DYLD_FRAMEWORK_PATH=str(products), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
    for key in ['GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL']:
        environment.pop(key, None)
    selected = args.only or list(CASES)
    for index, git in enumerate(engines):
        fixture = folder / ('engine-' + str(index)); fixture.mkdir()
        print('Checking RefLog families with ' + str(git), flush=True)
        receiver = subprocess.Popen([str(executable), str(fixture), str(git), *selected], cwd=root, env=environment, start_new_session=True)
        try:
            try: code = receiver.wait(timeout=600)
            except subprocess.TimeoutExpired as error:
                phase = fixture / 'phase.txt'
                raise RuntimeError('RefLog runtime exceeded 600 seconds at ' + (phase.read_text() if phase.exists() else 'startup')) from error
            if code: raise RuntimeError('RefLog receiver exited ' + str(code) + ' at ' + (fixture / 'phase.txt').read_text())
        finally:
            cleanup['close_receiver'](receiver)
            print('Owned receiver reaped: ' + str(receiver.pid), flush=True)
