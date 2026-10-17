"""Link native QA to the actual Debug app once; preserve each fixture's CLI.

The shared dylib contains the existing app objects, not a rebuilt/test variant.
Every fixture still gets its own entry point, process, repositories and assertions.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import tempfile
import time

ENTRY = re.compile(r'@main\s+(?:struct|enum|class)\s+(\w+)')


def fingerprint(files, settings, relative_to=None):
    digest = hashlib.sha256(json.dumps(settings, sort_keys=True).encode())
    for path in sorted(set(map(Path, files))):
        digest.update(str(path.relative_to(relative_to) if relative_to else path).encode()); digest.update(b'\0')
        with path.open('rb') as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b''):
                digest.update(chunk)
    return digest.hexdigest()


def build_receiver(root: Path, fixtures: list[Path], directory: Path) -> Path:
    root = root.resolve(); fixtures = [path.resolve() for path in fixtures]
    products = root / 'build/Build/Products/Debug'
    objects = sorted((root / 'build/Build/Intermediates.noindex/TurtleGitMac.build/Debug/TurtleGitMac.build/Objects-normal' / platform.machine()).glob('*.o'))
    module = products / 'TurtleGitMac.swiftmodule'
    if not objects or not module.is_dir():
        raise RuntimeError('Build TurtleGitMac Debug with testability before linking native QA.')
    sources_by_name = {path.stem: path for path in (root / 'Sources/TurtleGitMac').glob('*.swift')}
    objects_by_name = {path.stem: path for path in objects}
    stale = [source.name for name, source in sources_by_name.items()
             if name not in objects_by_name or source.stat().st_mtime_ns > objects_by_name[name].stat().st_mtime_ns]
    if stale:
        raise RuntimeError('Rebuild Debug before native QA; stale/missing objects: ' + ', '.join(stale))
    compiler = subprocess.check_output(['xcrun', 'swiftc', '--version']).decode()
    sdk = subprocess.check_output(['xcrun', '--show-sdk-path']).decode().strip()
    sdk_build = subprocess.check_output(['xcrun', '--show-sdk-build-version']).decode().strip()
    imported = [module, products / 'TurtleGitCore.framework', products / 'TurtleGitSMTP.framework']
    inputs = [Path(__file__).resolve(), *objects] + sorted((root / 'Sources/TurtleGitMac').glob('*.swift'))
    for item in imported:
        inputs += [path for path in item.rglob('*') if path.is_file() and not path.is_symlink()]
    settings = dict(version=1, architecture=platform.machine(), target=platform.machine() + '-apple-macos13.0', compiler=compiler, sdk=sdk, sdk_build=sdk_build, language='5', optimization='Onone', linker='shared-debug-objects')
    generation = root / 'build/qa/native-receivers/linked' / fingerprint(inputs, settings)
    generation.mkdir(parents=True, exist_ok=True)
    library = generation / 'libTurtleGitNativeQA.dylib'
    if not library.is_file():
        with tempfile.TemporaryDirectory(prefix='link-', dir=generation) as staging:
            output = Path(staging) / library.name
            subprocess.run(['xcrun', 'swiftc', '-emit-library', '-module-name', 'TurtleGitNativeQALink',
                            '-target', settings['target'], '-F', str(products), *map(str, objects),
                            '-framework', 'TurtleGitCore', '-Xlinker', '-rpath', '-Xlinker', str(products),
                            '-Xlinker', '-install_name', '-Xlinker', '@rpath/' + library.name,
                            '-o', str(output)], cwd=root, check=True, timeout=300)
            output.replace(library)
        print('Native QA: linked current Debug app objects once.', flush=True)
    sources = []
    main_name = None
    main_async = False
    main_throws = False
    for index, fixture in enumerate(fixtures):
        text = fixture.read_text()
        entry = ENTRY.search(text)
        if entry:
            if main_name is not None:
                raise RuntimeError('Native fixture group must have exactly one @main entry.')
            main_name = entry.group(1)
            tail = text[entry.end():]
            signature = re.search(r'\bstatic\s+func\s+main\s*\([^)]*\)\s*(async)?\s*(throws)?', tail)
            if not signature:
                raise RuntimeError('Native fixture main() signature unavailable: ' + str(fixture))
            main_async = signature.group(1) is not None
            main_throws = signature.group(2) is not None
            text = text[:entry.start()] + text[entry.start():].replace('@main', '', 1)
        source = directory / ('LinkedFixture' + str(index) + '.swift')
        source.write_text('@testable import TurtleGitMac\n#sourceLocation(file: ' + json.dumps(str(fixture)) + ', line: 1)\n' + text)
        sources.append(source)
    if main_name is None:
        raise RuntimeError('Missing native fixture @main entry.')
    main = directory / 'LinkedMain.swift'
    call = ('try ' if main_throws else '') + ('await ' if main_async else '') + main_name + '.main()'
    action = call + ('; exit(0)' if main_async else '; return 0')
    if main_throws:
        action = 'do { ' + action + ' } catch { fputs("Native QA failed: \\(error)\\n", stderr); ' + ('exit(1)' if main_async else 'return 1') + ' }'
    if main_async:
        body = 'NSApplication.shared.setActivationPolicy(.prohibited)\n    Task { @MainActor in ' + action + ' }\n    NSApplication.shared.run(); return 0'
    else:
        body = 'return MainActor.assumeIsolated { ' + action + ' }'
    main.write_text('import AppKit\n@_cdecl("turtlegit_native_qa_main") func nativeBootstrap() -> Int32 {\n    ' + body + '\n}\n')
    recipe = fingerprint([*sources, main], settings, relative_to=directory)
    executable = generation / ('receiver-' + recipe)
    if not executable.is_file():
        output = directory / 'linked-receiver'
        subprocess.run(['xcrun', 'swiftc', '-whole-module-optimization', '-Onone', '-parse-as-library',
                        '-swift-version', '5', '-target', settings['target'], '-I', str(products), '-F', str(products),
                        *map(str, sources), str(main), '-L', str(generation), '-lTurtleGitNativeQA',
                        '-framework', 'TurtleGitCore', '-Xlinker', '-rpath', '-Xlinker', str(products),
                        '-Xlinker', '-rpath', '-Xlinker', str(generation),
                        '-Xlinker', '-e', '-Xlinker', '_turtlegit_native_qa_main', '-o', str(output)],
                       cwd=root, check=True, timeout=300)
        output.replace(executable)
        print('Native QA: compiled fixture only: ' + ', '.join(path.name for path in fixtures), flush=True)
    else:
        print('Native QA: reused unchanged fixture: ' + ', '.join(path.name for path in fixtures), flush=True)
    return executable


def signal_receiver_group(pid, number):
    """Darwin may report EPERM for an orphan's zombie-only process group.

    Only confirm that case with the process table; a live member or an unreadable
    table retains the error. Signal numbers and the owned PGID stay unchanged.
    """
    try:
        os.killpg(pid, number)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        table = subprocess.run(['ps', '-axo', 'pgid=,stat='], capture_output=True, text=True)
        if table.returncode != 0:
            raise
        try:
            rows = [(int(fields[0]), fields[1]) for line in table.stdout.splitlines()
                    if (fields := line.split())]
        except (ValueError, IndexError):
            raise PermissionError('Cannot verify owned process group state')
        if not rows:
            raise PermissionError("Cannot verify an empty process table")
        members = [state for group, state in rows if group == pid]
        if not members or all(state.startswith('Z') for state in members):
            return False
        raise


def close_receiver(receiver):
    """Stop the owned process group, reap its leader, then terminate leftovers."""
    signal_receiver_group(receiver.pid, signal.SIGTERM)
    try:
        receiver.wait(timeout=5)
    except subprocess.TimeoutExpired:
        signal_receiver_group(receiver.pid, signal.SIGKILL)
        receiver.wait()
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if not signal_receiver_group(receiver.pid, 0):
            return
        time.sleep(0.05)
    signal_receiver_group(receiver.pid, signal.SIGKILL)


def sample_receiver(pid, destination):
    """Capture only an explicitly owned timed-out receiver before reaping it."""
    destination = Path(destination).resolve()
    try:
        destination.parent.mkdir(parents=True, exist_ok=True)
        result = subprocess.run(['/usr/bin/sample', str(pid), '2', '10', '-file', str(destination)],
                                capture_output=True, text=True, timeout=10)
        print('Owned receiver stack sample: ' + str(destination) + ' (exit ' + str(result.returncode) + ')', flush=True)
        if result.returncode:
            print((result.stdout + result.stderr)[-2000:], flush=True)
    except (OSError, subprocess.TimeoutExpired) as error:
        # Sampling is diagnostic only. The original receiver timeout and its
        # mandatory process-group cleanup must remain authoritative.
        print('Owned receiver stack sample unavailable: ' + str(error), flush=True)


def run_receiver(command, *, timeout=300, timeout_sample=None, **kwargs):
    """subprocess.run-compatible native execution with owned bounded cleanup."""
    check = kwargs.pop('check', False)
    input_data = kwargs.pop('input', None)
    if input_data is not None:
        if kwargs.get('stdin') is not None:
            raise ValueError('stdin and input arguments may not both be used')
        kwargs['stdin'] = subprocess.PIPE
    if kwargs.pop('capture_output', False):
        if kwargs.get('stdout') is not None or kwargs.get('stderr') is not None:
            raise ValueError('stdout and stderr arguments may not be used with capture_output')
        kwargs.update(stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    receiver = subprocess.Popen(command, start_new_session=True, **kwargs)
    try:
        stdout, stderr = receiver.communicate(input=input_data, timeout=timeout)
        result = subprocess.CompletedProcess(command, receiver.returncode, stdout, stderr)
        if check:
            result.check_returncode()
        return result
    except subprocess.TimeoutExpired as error:
        if timeout_sample is not None and receiver.poll() is None:
            sample_receiver(receiver.pid, timeout_sample)
        # communicate retains captured bytes on TimeoutExpired, including when
        # text=True. Preserve the original exception and emit bounded tails so
        # CI does not lose the fixture's last owned phase before cleanup.
        for name, payload in [('stdout', error.stdout), ('stderr', error.stderr)]:
            if payload:
                message = payload if isinstance(payload, str) else payload.decode('utf-8', errors='replace')
                print('Native receiver timeout ' + name + ' (last 65536 characters):\n' + message[-65536:], flush=True)
        raise
    finally:
        try:
            close_receiver(receiver)
        finally:
            # A timeout retains Popen through its exception traceback. Reaping
            # alone leaves its captured pipes open until that traceback dies.
            for stream in (receiver.stdin, receiver.stdout, receiver.stderr):
                if stream is not None:
                    try:
                        stream.close()
                    except OSError:
                        pass
        print('Owned receiver reaped: ' + str(receiver.pid), flush=True)
