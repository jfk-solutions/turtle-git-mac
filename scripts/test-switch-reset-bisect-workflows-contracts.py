#!/usr/bin/env python3
"""Offline contracts for bounded native family compilation and runtime coverage."""
import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location('switch_reset_bisect_cli', ROOT/'scripts/test-switch-reset-bisect-workflows.py')
CLI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CLI)
PASS = 'PASS: Switch/Reset/Bisect workflow completed\n'
EXPECTED = ['switch', 'reset', 'bisect', 'routing', 'switch-progress', 'switch-pickers',
            'reference-switch', 'reflog-switch', 'reset-progress', 'reset-picker',
            'reset-workflow', 'reset-modified', 'bisect-progress', 'bisect-lifecycle', 'retained-bisect']


class SwitchResetBisectContracts(unittest.TestCase):
    def exercise(self, selected, engines, *, failure=None, marker=True, compile_failure=False):
        builds, calls = [], []
        with tempfile.TemporaryDirectory(prefix='turtlegit-operation-contract-') as temporary:
            folder = Path(temporary)

            def build(root, sources, directory):
                self.assertEqual(root, ROOT)
                self.assertEqual(directory.parent, folder)
                self.assertEqual(sources[-1].name, 'SwitchResetBisectMain.swift')
                self.assertTrue(all(source.parent == directory for source in sources))
                builds.append((directory.name.removeprefix('family-'), sources, sources[-1].read_text()))
                if compile_failure:
                    raise subprocess.CalledProcessError(1, ['fake-compiler'])
                return directory/'fake-receiver'

            def run(argv, **kwargs):
                case = kwargs['env']['TURTLEGIT_SWITCH_RESET_BISECT_CASE']
                directory = Path(argv[1])
                self.assertEqual(kwargs['cwd'], ROOT)
                self.assertTrue(kwargs['capture_output'] and kwargs['text'])
                self.assertNotIn('timeout', kwargs)  # Existing native_receiver policy remains authoritative.
                self.assertEqual(Path(argv[0]).parent.name, 'family-'+CLI.family_for(case))
                self.assertEqual(directory.parent, folder)
                self.assertEqual(Path(kwargs['env']['GIT_CONFIG_GLOBAL']).read_text(), '')
                self.assertEqual(kwargs['env']['XDG_CONFIG_HOME'], str(directory/'xdg'))
                self.assertEqual(kwargs['env']['GIT_CONFIG_NOSYSTEM'], '1')
                self.assertNotIn('GIT_CONFIG_PARAMETERS', kwargs['env'])
                self.assertNotIn('GIT_AUTHOR_NAME', kwargs['env'])
                calls.append((case, argv[2], directory.name))
                return subprocess.CompletedProcess(argv, 1 if failure == case else 0, PASS if marker else '', '')

            with contextlib.redirect_stdout(io.StringIO()):
                CLI.run_workflows(ROOT, folder, selected, engines, build=build, run=run,
                                  environ={'GIT_CONFIG_PARAMETERS':'discard', 'GIT_AUTHOR_NAME':'discard'})
            return builds, calls

    def test_default_case_roster_and_family_partition_are_complete(self):
        self.assertEqual(list(CLI.CASES), EXPECTED)
        self.assertEqual(set(CLI.FAMILIES), {'switch', 'reset', 'bisect'})
        flattened = [case for cases in CLI.FAMILIES.values() for case in cases]
        self.assertCountEqual(flattened, EXPECTED)
        self.assertEqual(len(flattened), len(set(flattened)))
        self.assertEqual(sorted(map(len, CLI.FAMILIES.values())), [4, 5, 6])
        for filename, _ in CLI.CASES.values():
            self.assertTrue((ROOT/'docs/qa'/filename).is_file())

    def test_original_fixture_bodies_and_assertions_are_preserved(self):
        for case, (filename, _) in CLI.CASES.items():
            with self.subTest(case=case):
                original = (ROOT/'docs/qa'/filename).read_text()
                actual = CLI.fixture_text(ROOT, filename)
                if case != 'retained-bisect':
                    self.assertEqual(actual, original.replace('@main ', '', 1))
                else:
                    helper = original[original.index('@MainActor func findTable('):original.index('@MainActor func findRebaseProbe(')]
                    body = original[original.index('@MainActor func verifyNativeBisect('):original.index('@MainActor func verify()')]
                    body = body.replace('FileManager.default.temporaryDirectory.appendingPathComponent', 'URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent')
                    self.assertEqual(actual, 'import AppKit\nimport SwiftUI\nimport TurtleGitCore\n'+helper+body)
                    self.assertIn('precondition(', body)
                    # There is no cross-family type dependency hidden in this extraction.
                    self.assertNotIn('BisectOperationVerification.', '\n'.join(line.split('//')[0] for line in actual.splitlines()))

    def test_default_builds_three_receivers_once_and_keeps_thirty_process_order(self):
        engines = [Path('/private/system-git'), Path('/private/bundled-git')]
        builds, calls = self.exercise(EXPECTED, engines)
        self.assertEqual([row[0] for row in builds], ['switch', 'reset', 'bisect'])
        self.assertEqual([(case, git) for case, git, _ in calls], [(case, str(git)) for case in EXPECTED for git in engines])
        self.assertEqual(len({directory for _, _, directory in calls}), 30)
        for family, sources, main in builds:
            expected_cases = [case for case in EXPECTED if case in CLI.FAMILIES[family]]
            self.assertEqual([source.name for source in sources[:-1]], [CLI.CASES[case][0] for case in expected_cases])
            for case, (_, call) in CLI.CASES.items():
                self.assertEqual(('case "'+case+'": '+call) in main, case in expected_cases)
            self.assertIn('method_exchangeImplementations(original, hidden)', main)
            self.assertIn('defer { method_exchangeImplementations(original, hidden) }', main)
            self.assertIn('alphaValue = 0', main)

    def test_subset_builds_requested_whole_families_and_preserves_requested_order(self):
        selected = ['reset-workflow', 'switch-pickers', 'reset']
        builds, calls = self.exercise(selected, [Path('/private/git')])
        self.assertEqual([row[0] for row in builds], ['reset', 'switch'])
        self.assertEqual([case for case, _, _ in calls], selected)
        self.assertEqual([len(sources)-1 for _, sources, _ in builds], [5, 6])
        self.assertTrue(all('case "retained-bisect":' not in main for _, _, main in builds))

    def test_failed_receiver_and_missing_completion_remain_failures(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.exercise(['switch', 'reset'], [Path('/private/git')], failure='switch')
        with self.assertRaisesRegex(SystemExit, 'before completion: switch'):
            self.exercise(['switch'], [Path('/private/git')], marker=False)

    def test_compile_failure_does_not_start_any_receiver(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.exercise(['switch'], [Path('/private/git')], compile_failure=True)

    def test_cli_preserves_selector_and_engine_routing(self):
        with patch.object(CLI, 'run_workflows') as run:
            self.assertEqual(CLI.main(['--only', 'bisect-progress', '--git', '/private/one', '--git', '/private/two']), 0)
            self.assertEqual(run.call_count, 1)
            root, folder, cases, engines = run.call_args.args
            self.assertEqual(root, ROOT)
            self.assertEqual(cases, ['bisect-progress'])
            self.assertEqual(engines, [Path('/private/one'), Path('/private/two')])
        self.assertFalse(folder.exists())
        with patch.object(CLI, 'run_workflows') as run:
            self.assertEqual(CLI.main([]), 0)
            self.assertEqual(run.call_args.args[2:], (EXPECTED, [Path('/usr/bin/git')]))


if __name__ == '__main__':
    unittest.main()
