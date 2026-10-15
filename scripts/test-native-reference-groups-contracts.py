#!/usr/bin/env python3
"""Guard native reference coverage, compile dependencies and engine/CLI ordering."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
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

    def test_cli_preserves_git_outer_loop_and_explicit_case_order(self):
        cases = dict.fromkeys(['a', 'b'])
        with patch.object(cli, 'inventory', return_value=(cases, ['a', 'b'], {}, {'a': set(), 'b': set()})), \
             patch.object(sys, 'argv', ['groups', '--only', 'b', '--only', 'a', '--git', '/first/git', '--git', '/second/git', '--group-size', '1']), \
             patch.object(cli.subprocess, 'run') as run, contextlib.redirect_stdout(io.StringIO()):
            cli.main()
        observed = []
        for call in run.call_args_list:
            command = call.args[0]
            observed.append((command[command.index('--git') + 1], command[command.index('--only') + 1]))
            self.assertTrue(call.kwargs['check'])
            self.assertEqual(call.kwargs['cwd'], root)
        self.assertEqual(observed, [('/first/git', 'b'), ('/first/git', 'a'), ('/second/git', 'b'), ('/second/git', 'a')])

    def test_compilation_failure_propagates_and_stops_later_groups(self):
        cases = dict.fromkeys(['a', 'b'])
        with patch.object(cli, 'inventory', return_value=(cases, ['a', 'b'], {}, {'a': set(), 'b': set()})), \
             patch.object(sys, 'argv', ['groups', '--compile-only', '--group-size', '1']), \
             patch.object(cli.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, ['swiftc'])) as run, \
             contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(subprocess.CalledProcessError): cli.main()
        self.assertEqual(run.call_count, 1)
        self.assertIn('--compile-only', run.call_args.args[0])


if __name__ == '__main__':
    unittest.main()
