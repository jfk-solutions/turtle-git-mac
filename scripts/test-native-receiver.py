#!/usr/bin/env python3
"""Exercise native QA subprocess ownership and content-key invalidation."""
import contextlib
import io
from pathlib import Path
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from native_receiver import fingerprint, run_receiver, signal_receiver_group


class ReceiverContracts(unittest.TestCase):
    def run_owned(self, script, **kwargs):
        with contextlib.redirect_stdout(io.StringIO()):
            return run_receiver([sys.executable, '-c', script], **kwargs)

    def test_stdout_stderr_input_and_checked_failure(self):
        result = self.run_owned('import sys; print(sys.stdin.read()); print("diagnostic", file=sys.stderr)',
                                input='fixture', capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout, 'fixture\n')
        self.assertEqual(result.stderr, 'diagnostic\n')
        with self.assertRaises(subprocess.CalledProcessError) as caught:
            self.run_owned('import sys; print("failed"); sys.exit(7)', capture_output=True, text=True, check=True)
        self.assertEqual(caught.exception.returncode, 7)
        self.assertEqual(caught.exception.stdout, 'failed\n')

    def test_timeout_reaps_exact_owned_process(self):
        with tempfile.TemporaryDirectory() as temporary:
            pidfile = Path(temporary) / 'pid'
            script = 'import os,time; from pathlib import Path; Path(' + repr(str(pidfile)) + ').write_text(str(os.getpid())); time.sleep(60)'
            with self.assertRaises(subprocess.TimeoutExpired):
                self.run_owned(script, timeout=1)
            pid = int(pidfile.read_text())
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
            with self.assertRaises(ChildProcessError):
                os.waitpid(pid, os.WNOHANG)

    def test_success_terminates_owned_descendant(self):
        with tempfile.TemporaryDirectory() as temporary:
            pidfile = Path(temporary) / 'pid'
            # A successful leader leaves a helper that cleanup must stop.
            script = '''import os,signal,time
from pathlib import Path
child=os.fork()
if child == 0:
    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
    Path(PIDFILE).write_text(str(os.getpid()))
    while True: time.sleep(1)
while not Path(PIDFILE).exists(): time.sleep(.01)
'''.replace('PIDFILE', repr(str(pidfile)))
            self.run_owned(script, check=True)
            pid = int(pidfile.read_text())
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    break
                # An orphan may briefly remain a zombie until launchd reaps it.
                state = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True).stdout.strip()
                if state.startswith('Z'):
                    break
                time.sleep(.05)
            else:
                self.fail('Owned descendant remained alive after receiver success')

    def test_darwin_permission_probe_accepts_only_empty_or_zombie_group(self):
        for output in ['8 S\n', '123 Z\n123 Zs\n8 S\n']:
            with self.subTest(table=output), patch('native_receiver.os.killpg', side_effect=PermissionError(1, 'Operation not permitted')) as send, patch('native_receiver.subprocess.run', return_value=subprocess.CompletedProcess([], 0, output, '')):
                self.assertFalse(signal_receiver_group(123, 0))
                send.assert_called_once_with(123, 0)

    def test_permission_error_for_live_group_or_unreadable_state_is_preserved(self):
        for status, output in [(0, '123 S\n123 Z\n'), (1, ''), (0, ''), (0, 'invalid row\n')]:
            with self.subTest(status=status, table=output), patch('native_receiver.os.killpg', side_effect=PermissionError(1, 'Operation not permitted')), patch('native_receiver.subprocess.run', return_value=subprocess.CompletedProcess([], status, output, '')):
                with self.assertRaises(PermissionError):
                    signal_receiver_group(123, signal.SIGTERM)

    def test_content_and_recipe_changes_invalidate_cache(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            inputs = []
            for name in ['App.o', 'App.swift', 'App.swiftmodule', 'Core', 'SMTP', 'helper.py', 'Fixture.swift']:
                file = base / name; file.write_bytes(b'original'); inputs.append(file)
            settings = dict(compiler='swift-A', sdk='sdk-A', architecture='arm64', flags=['Onone'])
            original = fingerprint(inputs, settings)
            for file in inputs:
                file.write_bytes(b'changed')
                self.assertNotEqual(fingerprint(inputs, settings), original, file.name)
                file.write_bytes(b'original')
            for key in settings:
                self.assertNotEqual(fingerprint(inputs, {**settings, key: 'different'}), original, key)
            self.assertEqual(fingerprint(inputs[::-1], settings), original)
            other = base / 'scratch'; other.mkdir()
            copies = []
            for file in inputs:
                copy = other / file.name; copy.write_bytes(file.read_bytes()); copies.append(copy)
            self.assertEqual(fingerprint(inputs, settings, relative_to=base),
                             fingerprint(copies, settings, relative_to=other))


if __name__ == '__main__':
    unittest.main()
