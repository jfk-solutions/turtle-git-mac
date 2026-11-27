#!/usr/bin/env python3
"""Offline contracts for independent receiver continuation and failed-only drain."""
import ast
import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
DRIVER = ROOT / 'scripts/test-native-reference-batch.py'
TREE = ast.parse(DRIVER.read_text())
NAMES = {'run_owned_reference_case', 'run_reference_plan', 'failed_reference_cleanup'}
SCOPE = dict(subprocess=subprocess, json=__import__('json'), importlib=__import__('importlib'), CASES={'a': '', 'b': ''})
exec(compile(ast.Module(body=[node for node in TREE.body if isinstance(node, ast.FunctionDef) and node.name in NAMES], type_ignores=[]), str(DRIVER), 'exec'), SCOPE)


class Receiver:
    pid = 12345
    returncode = None
    def __init__(self, result, events):
        self.result, self.events = result, events
    def wait(self, timeout):
        self.events.append(('wait', timeout))
        if isinstance(self.result, BaseException):
            raise self.result
        self.returncode = self.result
        return self.result


class BatchContracts(unittest.TestCase):
    def case(self, result, cleanup_error=None):
        events = []
        receiver = Receiver(result, events)
        def close(value):
            self.assertIs(value, receiver)
            events.append('reap')
            if value.returncode is None:
                value.returncode = -15
        def drain():
            self.assertIn('reap', events)
            events.append('drain')
            if cleanup_error:
                raise cleanup_error
            return True
        with contextlib.redirect_stdout(io.StringIO()):
            row = SCOPE['run_owned_reference_case'](receiver, close, drain)
        return row, events

    def test_success_reaps_without_expensive_helper_scan(self):
        row, events = self.case(0)
        self.assertEqual(events, [('wait', 300), 'reap'])
        self.assertEqual(row, dict(returncode=0, timeout=False, cleanup_complete=True))

    def test_nonzero_reaps_before_failed_only_drain(self):
        row, events = self.case(9)
        self.assertEqual(events, [('wait', 300), 'reap', 'drain'])
        self.assertEqual(row['returncode'], 9)
        self.assertTrue(row['cleanup_complete'])
        self.assertTrue(row['fallback_helper_cleanup'])

    def test_timeout_preserves_budget_and_reaps_before_drain(self):
        row, events = self.case(subprocess.TimeoutExpired(['receiver'], 300))
        self.assertEqual(events, [('wait', 300), 'reap', 'drain'])
        self.assertTrue(row['timeout'])
        self.assertEqual(row['returncode'], -15)

    def test_unknown_or_uninspectable_cleanup_stops_remaining_engines(self):
        row, _ = self.case(1, RuntimeError('unknown private image'))
        calls = []
        def run(index, engine, case):
            calls.append((index, engine, case))
            return row
        with contextlib.redirect_stdout(io.StringIO()):
            results = SCOPE['run_reference_plan'](['system', 'bundled'], ['a', 'b'], run)
        self.assertEqual(calls, [(0, 'system', 'a')])
        self.assertFalse(results[0]['cleanup_complete'])
        self.assertIn('unknown private image', results[0]['cleanup_error'])

    def test_drained_failure_continues_all_cases_and_both_engines(self):
        calls = []
        def run(index, engine, case):
            calls.append((index, engine, case))
            return self.case(7 if (index, case) == (0, 'a') else 0)[0]
        with contextlib.redirect_stdout(io.StringIO()):
            results = SCOPE['run_reference_plan'](['system', 'bundled'], ['a', 'b'], run)
        self.assertEqual(calls, [(0, 'system', 'a'), (0, 'system', 'b'), (1, 'bundled', 'a'), (1, 'bundled', 'b')])
        self.assertEqual([row['returncode'] for row in results], [7, 0, 0, 0])

    def test_interrupt_is_not_collected_as_an_ordinary_case_failure(self):
        events = []
        receiver = Receiver(KeyboardInterrupt(), events)
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(KeyboardInterrupt):
            SCOPE['run_owned_reference_case'](receiver, lambda _: events.append('reap'), lambda: events.append('drain'))
        self.assertEqual(events, [('wait', 300), 'reap'])

    def test_launch_failure_is_not_swallowed_by_plan(self):
        with self.assertRaisesRegex(OSError, 'cannot launch'):
            SCOPE['run_reference_plan'](['system', 'bundled'], ['a', 'b'], lambda *_: (_ for _ in ()).throw(OSError('cannot launch')))

    def test_failed_cleanup_uses_reviewed_module_exact_image_and_private_contexts(self):
        calls = []
        module = types.SimpleNamespace(
            approved_images=lambda root, git: {'/approved/git'},
            cleanup_group=lambda context, images: calls.append((context, set(images))) or True)
        spec = types.SimpleNamespace(loader=types.SimpleNamespace(exec_module=lambda _: None))
        with patch.object(importlib.util, 'spec_from_file_location', return_value=spec) as load, \
             patch.object(importlib.util, 'module_from_spec', return_value=module):
            result = SCOPE['failed_reference_cleanup'](ROOT, Path('/usr/bin/git'), Path('/private/exact-reference'), [Path('/private/batch'), Path('/tmp/tg-ssh-case')])
        self.assertTrue(result)
        load.assert_called_once_with('reference_batch_cleanup', ROOT / 'scripts/test-native-reference-groups.py')
        self.assertEqual([context for context, _ in calls], [Path('/private/batch').resolve(), Path('/tmp/tg-ssh-case').resolve()])
        self.assertTrue(all(images == {'/approved/git', str(Path('/private/exact-reference').resolve())} for _, images in calls))

    def test_runtime_default_and_private_temp_contract_stay_discoverable(self):
        # Inventory imports no executable driver; retain its literal loop API.
        from native_reference_groups import inventory
        cases, default, _, _ = inventory(ROOT)
        self.assertIn('history-workflows', default)
        self.assertEqual(len(default), len(set(default)))
        self.assertIn('finder-service-grant-worker', cases)
        source = DRIVER.read_text()
        self.assertIn("TMPDIR=str((fixture / 'temporary') if case == 'ssh-coordinator' else (private_environment / 'temporary')) + os.sep", source)
        self.assertIn("start_new_session=True", source)


if __name__ == '__main__':
    unittest.main()
