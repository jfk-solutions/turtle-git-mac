#!/usr/bin/env python3
"""Guard native reference coverage, compile dependencies and engine/CLI ordering."""
import contextlib
import importlib.util
import io
import json
import os
import shutil
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
from native_reference_groups import inventory, plan

root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('reference_groups_cli', root / 'scripts/test-native-reference-groups.py')
cli = importlib.util.module_from_spec(spec); spec.loader.exec_module(cli)


class ReferenceGroupContracts(unittest.TestCase):
    def test_default_preserves_every_runtime_case_and_original_typechecks(self):
        cases, default, paths, dependencies = inventory(root)
        groups = plan(cases, default, dependencies, 12, check_all=True)
        self.assertEqual([case for row in groups for case in row['run']], default)
        self.assertEqual({case for row in groups for case in row['compile'] + row['include']}, set(cases))
        self.assertEqual(len(default), len(set(default)))
        self.assertTrue(all(path.is_file() for path in paths.values()))
        self.assertTrue(all(len(row['compile']) <= 12 for row in groups))
        self.assertTrue(all(not row['run'] or row['run'] == row['compile'] for row in groups))
        for row in groups:
            compiled = set(row['compile'] + row['include'])
            for case in compiled:
                self.assertLessEqual(dependencies[case], compiled)
        for parent, worker in [('finder-service-grants', 'finder-service-grant-worker'), ('finder-publication', 'finder-publication-worker')]:
            group = next(row for row in groups if parent in row['run'])
            self.assertIn(worker, group['include'] + group['compile'])
            self.assertNotIn(worker, default)

    def test_original_cases_cannot_be_silently_removed_or_reclassified(self):
        baseline = json.loads((root / 'scripts/native-reference-baseline.json').read_text())
        cases, default, _, _ = inventory(root)
        for case, entry in baseline['cases'].items():
            self.assertEqual(cases.get(case), entry, case)
        expected = [case for case in baseline['cases'] if case not in baseline['runtime_excluded']]
        self.assertEqual([case for case in default if case in baseline['cases']], expected)

    def test_dependency_closure_never_executes_helper_and_handles_cycle(self):
        cases = dict.fromkeys(['case', 'helper', 'worker', 'capture'])
        dependencies = {'case': {'helper'}, 'helper': {'worker'}, 'worker': {'helper'}, 'capture': set()}
        groups = plan(cases, ['case'], dependencies, 1, check_all=True)
        self.assertEqual([case for row in groups for case in row['run']], ['case'])
        main = next(row for row in groups if row['run'])
        self.assertEqual(main['include'], ['helper', 'worker'])
        self.assertEqual(groups[0]['compile'], ['capture'])
        self.assertEqual(groups[0]['run'], [])

    def execute_fake(self, arguments, outcomes, cleanup_outcomes=None):
        cases = dict.fromkeys(['a', 'b'])
        reports = []
        def record(path, rows, total):
            reports.append((json.loads(json.dumps(rows)), total))
        with patch.object(cli, 'inventory', return_value=(cases, ['a', 'b'], {}, {'a': set(), 'b': set()})), \
             patch.object(sys, 'argv', ['groups'] + arguments), \
             patch.object(cli.subprocess, 'run', side_effect=outcomes) as run, \
             patch.object(cli, 'approved_images', return_value={'/fake/git'}), \
             patch.object(cli, 'cleanup_group', return_value=False, side_effect=cleanup_outcomes), \
             patch.object(cli, 'write_results', side_effect=record), contextlib.redirect_stdout(io.StringIO()):
            code = cli.main()
        return code, run.call_args_list, reports

    def test_cli_preserves_git_outer_loop_and_explicit_case_order(self):
        success = subprocess.CompletedProcess([], 0)
        code, calls, reports = self.execute_fake(
            ['--only', 'b', '--only', 'a', '--git', '/first/git', '--git', '/second/git', '--group-size', '1'],
            [success] * 4)
        self.assertEqual(code, 0)
        observed = []
        for call in calls:
            command = call.args[0]
            observed.append((command[command.index('--git') + 1], command[command.index('--only') + 1]))
            self.assertFalse(call.kwargs['check'])
            self.assertEqual(call.kwargs['cwd'], root)
        self.assertEqual(observed, [('/first/git', 'b'), ('/first/git', 'a'), ('/second/git', 'b'), ('/second/git', 'a')])
        self.assertEqual([row['status'] for row in reports[-1][0]], ['passed'] * 4)
        self.assertEqual(reports[-1][1], 4)

    def test_failed_groups_continue_across_engines_and_aggregate_exact_codes(self):
        outcomes = [subprocess.CompletedProcess([], value) for value in (17, 0, 0, -9)]
        code, calls, reports = self.execute_fake(
            ['--only', 'a', '--only', 'b', '--git', '/first/git', '--git', '/second/git', '--group-size', '1'], outcomes)
        self.assertEqual(code, 1)
        self.assertEqual(len(calls), 4)
        rows, total = reports[-1]
        self.assertEqual(total, 4)
        self.assertEqual([(row['engine'], row['group'], row['returncode'], row['status']) for row in rows],
                         [('/first/git', 1, 17, 'failed'), ('/first/git', 2, 0, 'passed'),
                          ('/second/git', 1, 0, 'passed'), ('/second/git', 2, -9, 'failed')])
        self.assertEqual([row['run'] for row in rows], [['a'], ['b'], ['a'], ['b']])
        self.assertTrue(any(rows and rows[-1]['status'] == 'running' for rows, _ in reports))

    def test_compilation_failure_continues_once_per_group_without_git(self):
        code, calls, reports = self.execute_fake(
            ['--compile-only', '--group-size', '1', '--git', '/first/git', '--git', '/second/git'],
            [subprocess.CompletedProcess([], 2), subprocess.CompletedProcess([], 0)])
        self.assertEqual(code, 1)
        self.assertEqual(len(calls), 2)
        for call in calls:
            self.assertIn('--compile-only', call.args[0])
            self.assertNotIn('--git', call.args[0])
        self.assertEqual([row['engine'] for row in reports[-1][0]], [None, None])
        self.assertTrue(all(row['compile_only'] for row in reports[-1][0]))

    def test_launch_failure_is_reported_and_does_not_hide_later_group(self):
        code, calls, reports = self.execute_fake(['--only', 'a', '--only', 'b', '--group-size', '1'],
            [OSError('synthetic launch refusal'), subprocess.CompletedProcess([], 0)])
        self.assertEqual(code, 1)
        self.assertEqual(len(calls), 2)
        rows, _ = reports[-1]
        self.assertEqual(rows[0]['status'], 'failed')
        self.assertIsNone(rows[0]['returncode'])
        self.assertIn('synthetic launch refusal', rows[0]['error'])
        later_status = rows[1]['status']
        self.assertEqual(later_status, 'passed')

    def test_list_never_executes_or_writes_results(self):
        code, calls, reports = self.execute_fake(['--list'], [])
        self.assertEqual(code, 0)
        self.assertEqual(calls, [])
        self.assertEqual(reports, [])

    def test_cleanup_refusal_stops_remaining_groups_and_engines(self):
        code, calls, reports = self.execute_fake(
            ['--only', 'a', '--only', 'b', '--git', '/first/git', '--git', '/second/git', '--group-size', '1'],
            [subprocess.CompletedProcess([], 7)], [RuntimeError('uninspectable private owner')])
        rows, total = reports[-1]
        context = Path(rows[0]['private_context'])
        try:
            self.assertEqual(code, 1)
            self.assertEqual(len(calls), 1)
            self.assertEqual(total, 4)
            self.assertEqual(rows[0]['returncode'], 7)
            self.assertFalse(rows[0]['cleanup_complete'])
            self.assertIn('uninspectable', rows[0]['cleanup_error'])
            self.assertTrue(context.is_dir())
        finally:
            shutil.rmtree(context)

    def test_drained_fallback_helper_is_not_a_false_green(self):
        code, calls, reports = self.execute_fake(['--only', 'a', '--only', 'b', '--group-size', '1'],
            [subprocess.CompletedProcess([], 0)] * 2, [True, False])
        self.assertEqual(code, 1)
        self.assertEqual(len(calls), 2)
        self.assertTrue(reports[-1][0][0]['cleanup_complete'])
        self.assertEqual(reports[-1][0][0]['status'], 'failed')
        self.assertTrue(reports[-1][0][0]['fallback_helper_cleanup'])
        self.assertEqual(reports[-1][0][1]['status'], 'passed')
        contexts = [call.kwargs['env']['TMPDIR'] for call in calls]
        self.assertEqual(len(set(contexts)), 2)
        self.assertTrue(all(not Path(context).exists() for context in contexts))

    def test_nul_lsof_parser_keeps_newline_unicode_and_deleted_resource_identity(self):
        context = Path('/private/qa-unique')
        path = str(context / '雪\np999').encode()
        records = cli.parse_process_files(b'p41\0fcwd\0tDIR\0n' + path + b' (deleted)\0\np42\0ftxt\0tREG\0n/fake/git\0')
        self.assertEqual(set(records), {41, 42})
        self.assertEqual(cli.private_path(records[41]['resources'][0], context), str(context / '雪\np999'))
        self.assertIsNone(cli.private_path('/private/qa-unique-other/file', context))

    def test_detached_owned_helper_is_revalidated_and_signalled_by_exact_pid(self):
        # A Git helper may have a new PGID: cleanup must not rely on the receiver
        # group or signal unrelated members of an otherwise shared process group.
        alive = {731: dict(images={'/fake/git'}, resources=['/private/qa/cwd (deleted)'], scripts=[])}
        signals = []
        def inspect(): return dict(alive)
        def identify(records, context, images):
            return {pid: ('same-start', frozenset({'/fake/git'})) for pid in records}
        def terminate(pid, number):
            signals.append((pid, number));alive.pop(pid)
        self.assertTrue(cli.cleanup_group(Path('/private/qa'), {'/fake/git'}, inspect=inspect, identify=identify,
            start=lambda pid: 'same-start' if pid in alive else None, signal_pid=terminate, pause=lambda _: None))
        self.assertEqual(signals, [(731, signal.SIGTERM)])
        self.assertEqual(alive, {})

    @unittest.skipUnless(sys.platform == 'darwin', 'Requires the actual macOS lsof deleted-cwd contract')
    def test_real_deleted_unicode_newline_cwd_helper_drains(self):
        with tempfile.TemporaryDirectory(prefix='reference-owned-deleted-cwd-') as temporary:
            context = Path(temporary).resolve()
            inner = context / 'owned 雪\nworking directory'
            inner.mkdir()
            child = subprocess.Popen(['/bin/sleep', '30'], cwd=inner, start_new_session=True,
                                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            reaper = None
            reap_errors = []
            try:
                self.assertEqual(os.getpgid(child.pid), child.pid)
                self.assertNotEqual(os.getpgrp(), child.pid)
                self.assertIsNone(child.poll())
                inner.rmdir()
                self.assertFalse(inner.exists())
                # This test is the child's parent. Reap concurrently, just as
                # the delegated driver's parent/launchd does after termination;
                # an unreaped zombie is not an executable cleanup survivor.
                def reap():
                    try:
                        child.wait(timeout=45)
                    except BaseException as error:
                        reap_errors.append(error)
                reaper = threading.Thread(target=reap, daemon=True)
                reaper.start()
                needed = cli.cleanup_group(context, {str(Path('/bin/sleep').resolve())})
                self.assertTrue(needed, 'Actual deleted cwd was not admitted as private ownership')
                reaper.join(timeout=5)
                self.assertFalse(reaper.is_alive(), 'Owned sleep was not reaped')
                self.assertEqual(reap_errors, [])
                self.assertIn(child.returncode, (-signal.SIGTERM, -signal.SIGKILL))
                with self.assertRaises(ProcessLookupError):
                    os.kill(child.pid, 0)
            finally:
                # Never signal a name or another group: this exact Popen child
                # is ours, including when the ownership assertion fails.
                if child.poll() is None:
                    child.kill()
                child.wait(timeout=5)
                if reaper is not None:
                    reaper.join(timeout=5)

    def test_unapproved_private_owner_refuses_without_signalling(self):
        record = {44: dict(images={'/unapproved/tool'}, resources=['/private/qa/deleted (deleted)'], scripts=[])}
        with patch.object(cli.os, 'kill') as kill:
            with self.assertRaisesRegex(RuntimeError, 'Unapproved owner'):
                cli.cleanup_group(Path('/private/qa'), {'/fake/git'}, inspect=lambda: record)
        kill.assert_not_called()

    def test_owned_helper_ignoring_term_is_killed_and_waited(self):
        alive = {731: dict(images={'/fake/git'}, resources=['/private/qa/file'], scripts=[])}
        signals = []
        def terminate(pid, number):
            signals.append((pid, number))
            if number == signal.SIGKILL: alive.pop(pid)
        with patch.object(cli.time, 'monotonic', side_effect=[0, 4, 5]):
            self.assertTrue(cli.cleanup_group(Path('/private/qa'), {'/fake/git'}, inspect=lambda: dict(alive),
                identify=lambda records, *_: {pid: ('same-start', frozenset({'/fake/git'})) for pid in records},
                start=lambda pid: 'same-start' if pid in alive else None, signal_pid=terminate, pause=lambda _: None))
        self.assertEqual(signals, [(731, signal.SIGTERM), (731, signal.SIGKILL)])
        self.assertFalse(alive)

    def test_shell_requires_exact_owned_script_argv_and_regular_resource(self):
        shell = str(Path('/bin/sh').resolve())
        record = {44: dict(images={shell}, resources=['/private/qa/script (deleted)'], scripts=['/private/qa/script (deleted)'])}
        with patch.object(cli, 'process_start', return_value='start'), \
             patch.object(cli.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '/bin/sh /private/qa/script --case', '')):
            self.assertEqual(set(cli.owned_processes(record, Path('/private/qa'), {'/fake/git'})), {44})
        with patch.object(cli.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '/bin/sh /unrelated/script --case', '')):
            with self.assertRaisesRegex(RuntimeError, 'Unapproved owner'):
                cli.owned_processes(record, Path('/private/qa'), {'/fake/git'})

    def test_reused_pid_is_not_signalled(self):
        record = {731: dict(images={'/fake/git'}, resources=['/private/qa/file'], scripts=[])}
        starts = iter(['replacement-start', None])
        inspect = iter([record, record, {}])
        signals = []
        self.assertTrue(cli.cleanup_group(Path('/private/qa'), {'/fake/git'}, inspect=lambda: next(inspect),
            identify=lambda records, *_: {pid: ('old-start', frozenset({'/fake/git'})) for pid in records},
            start=lambda pid: next(starts), signal_pid=lambda *args: signals.append(args), pause=lambda _: None))
        self.assertEqual(signals, [])

    def test_cli_process_returns_nonzero_for_any_failed_group_and_zero_for_all_pass(self):
        # Real Python CLI/exit handling with tiny authored fake driver processes:
        # this exercises no native compilation, receiver, repository or Git.
        source = (root / 'scripts/test-native-reference-groups.py').read_text()
        # Keep this real CLI test synthetic: OS ownership inspection is covered
        # separately below with explicit fake process records/signals.
        source = source.replace('    sys.exit(main())', "    cleanup_group = lambda *args: False\n    approved_images = lambda *args: set()\n    sys.exit(main())")
        with tempfile.TemporaryDirectory(prefix='reference-group-cli-') as temporary:
            folder = Path(temporary).resolve()
            scripts = folder / 'scripts'; scripts.mkdir()
            runner = scripts / 'test-native-reference-groups.py'; runner.write_text(source)
            (scripts / 'native_reference_groups.py').write_text(
                "def inventory(root):\n    return {'a': None, 'b': None}, ['a', 'b'], {}, {}\n"
                "def plan(cases, selected, dependencies, size, check_all=False):\n"
                "    return [dict(run=[case], compile=[case], include=[]) for case in selected]\n")
            (scripts / 'test-native-reference-batch.py').write_text(
                "import json, os, pathlib, sys\n"
                "case = sys.argv[sys.argv.index('--only') + 1]\n"
                "engine = sys.argv[sys.argv.index('--git') + 1]\n"
                "with pathlib.Path(__file__).parents[1].joinpath('calls.jsonl').open('a') as log:\n"
                "    log.write(json.dumps([engine, case]) + '\\n')\n"
                "sys.exit(9 if os.environ.get('REFERENCE_GROUP_FAKE_FAILURE') == case else 0)\n")
            expected = [['/first/git', 'a'], ['/first/git', 'b'], ['/second/git', 'a'], ['/second/git', 'b']]
            for failure, exitcode in [('a', 1), ('', 0)]:
                with self.subTest(failure=failure):
                    calls = folder / 'calls.jsonl'
                    if calls.exists(): calls.unlink()
                    report = folder / 'results.json'
                    environment = dict(os.environ, REFERENCE_GROUP_FAKE_FAILURE=failure)
                    result = subprocess.run([sys.executable, str(runner), '--git', '/first/git', '--git', '/second/git', '--group-size', '1', '--results', str(report)],
                                            capture_output=True, text=True, env=environment, timeout=20)
                    self.assertEqual(result.returncode, exitcode, result.stdout + result.stderr)
                    self.assertEqual([json.loads(line) for line in calls.read_text().splitlines()], expected)
                    summary = json.loads(report.read_text())
                    self.assertTrue(summary['complete'])
                    self.assertEqual(summary['total_groups'], 4)
                    self.assertEqual(summary['failed_groups'], 2 if failure else 0)
                    self.assertEqual(summary['passed_groups'], 2 if failure else 4)


if __name__ == '__main__':
    unittest.main()
