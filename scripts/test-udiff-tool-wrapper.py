#!/usr/bin/env python3
"""Private process-only verification of the waiting Unified Diff wrapper.

This never launches TurtleGit: both executable selection routes target owned
fake executables. No preferences, pasteboards, App Group, or user repository.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
WRAPPER = ROOT / 'scripts/turtlegit-udiff'

HELPER = '''import json, os, sys, time
from pathlib import Path
receipt=Path(os.environ['TURTLEGIT_WRAPPER_RECEIPT'])
pending=receipt.with_suffix('.pending')
pending.write_text(json.dumps({'argv':sys.argv[1:], 'pid':os.getpid(), 'cwd':os.getcwd()}, ensure_ascii=False), encoding='utf-8')
pending.replace(receipt)
while not Path(os.environ['TURTLEGIT_WRAPPER_GATE']).exists():
    time.sleep(.01)
source=sys.stdin.buffer.read()
sys.stdout.buffer.write(b'wrapper stdout\\x00\\xff:'+source)
sys.stdout.buffer.flush()
sys.stderr.buffer.write(b'wrapper stderr\\x00\\xfe\\n')
sys.stderr.buffer.flush()
sys.exit(37)
'''


def helper(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('#!' + sys.executable + '\n' + HELPER, encoding='utf-8')
    path.chmod(0o700)


def exercise(folder, name, executable, arguments, source, *, app=None, redirected=False, timeout=10):
    receipt, gate = folder / (name + '.json'), folder / (name + '.gate')
    env = dict(os.environ, TURTLEGIT_WRAPPER_RECEIPT=str(receipt), TURTLEGIT_WRAPPER_GATE=str(gate))
    env['TURTLEGIT_UDIFF_EXECUTABLE'] = str(executable) if executable else ''
    env['TURTLEGIT_APP'] = str(app or folder / 'must-not-be-used.app')
    stream = None
    process = None
    try:
        if redirected:
            path = folder / (name + '.stdin')
            path.write_bytes(b'xx' + source)
            stream = path.open('rb'); stream.seek(2)
        process = subprocess.Popen([str(WRAPPER), *arguments], cwd=folder, env=env,
                                   stdin=stream if redirected else subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        deadline = time.monotonic() + timeout
        while not receipt.exists():
            if process.poll() is not None:
                raise AssertionError('Wrapper exited before its owned helper started: ' + name)
            if time.monotonic() >= deadline:
                raise TimeoutError('Owned wrapper helper did not start: ' + name)
            time.sleep(.01)
        recorded = json.loads(receipt.read_text(encoding='utf-8'))
        assert recorded['argv'] == ['--unified-diff-tool', *arguments], recorded
        assert recorded['pid'] == process.pid, 'Wrapper did not exec the selected binary'
        assert Path(recorded['cwd']).samefile(folder), recorded
        assert process.poll() is None, 'Wrapper detached before helper completion'
        gate.write_bytes(b'continue')
        stdout, stderr = process.communicate(input=None if redirected else source, timeout=timeout)
        (folder / (name + '.stdout')).write_bytes(stdout)
        (folder / (name + '.stderr')).write_bytes(stderr)
        assert process.returncode == 37, process.returncode
        assert stdout == b'wrapper stdout\x00\xff:' + source, 'stdin/stdout bytes were transformed'
        assert stderr == b'wrapper stderr\x00\xfe\n', 'stderr bytes were transformed'
        assert process.poll() is not None, 'Owned helper was not reaped'
    finally:
        if process is not None and process.poll() is None:
            process.kill()
            stdout, stderr = process.communicate(timeout=5)
            (folder / (name + '.terminated.stdout')).write_bytes(stdout)
            (folder / (name + '.terminated.stderr')).write_bytes(stderr)
        if stream is not None:
            stream.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--timeout', type=float, default=10)
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error('--timeout must be positive')
    with tempfile.TemporaryDirectory(prefix='tg-udiff-wrapper-') as temporary:
        folder = Path(temporary)
        try:
            binary = folder / 'fake executable 雪 with spaces'
            helper(binary)
            injection = folder / 'must not be created'
            arguments = ['--title', '  "雪"\n--command=log\t', '--',
                         "Cafe\u0301 'literal' [*]? $(touch " + str(injection) + ') `literal` file']
            exercise(folder, 'explicit-binary', binary, arguments, bytes(range(256)) * 257, timeout=args.timeout)
            assert not injection.exists(), 'Wrapper evaluated a literal shell metacharacter'
            app = folder / 'private TurtleGit 雪.app'
            helper(app / 'Contents/MacOS/TurtleGitMac')
            exercise(folder, 'app-fallback', None, ['/p', '/title:Café "stream"'], b'\x00\xff\r\nredirected\x80',
                     app=app, redirected=True, timeout=args.timeout)
            exercise(folder, 'default-stdin', binary, [], b'', timeout=args.timeout)
            for name, path in [('missing', folder / 'missing binary'), ('not-executable', folder / 'not executable')]:
                if name == 'not-executable':
                    path.write_text('not executable', encoding='utf-8'); path.chmod(0o600)
                env = dict(os.environ, TURTLEGIT_UDIFF_EXECUTABLE=str(path), TURTLEGIT_APP=str(app))
                result = subprocess.run([str(WRAPPER)], cwd=folder, env=env, input=b'private input',
                                        capture_output=True, timeout=args.timeout)
                assert result.returncode == 127 and not result.stdout, result
                assert str(path).encode() in result.stderr and b'executable not found' in result.stderr, result.stderr
            print('PASS: Unified Diff wrapper exec identity, waiting, literal argv, streams, selection and exit status', flush=True)
        except BaseException:
            destination = ROOT / 'build/qa' / ('udiff-wrapper-failed-' + uuid.uuid4().hex)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(folder, destination)
            print('Retained owned wrapper evidence: ' + str(destination), file=sys.stderr, flush=True)
            raise


if __name__ == '__main__':
    main()
