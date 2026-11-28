#!/usr/bin/env python3
"""Preserve native engine invocation context across finalized runtime relocation."""
import ast
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
DRIVER = ROOT / 'scripts/check-cherry-pick-native.py'
TREE = ast.parse(DRIVER.read_text())
SCOPE = {}
exec(compile(ast.Module(body=[node for node in TREE.body
                             if isinstance(node, ast.FunctionDef) and node.name == 'native_git_invocation'],
                        type_ignores=[]), str(DRIVER), 'exec'), SCOPE)


class NativeEngineInvocationTests(unittest.TestCase):
    def test_finalized_logical_engine_survives_both_runtime_and_binary_symlinks(self):
        with tempfile.TemporaryDirectory(prefix='turtlegit-engine-layout-') as temporary:
            contents = Path(temporary) / 'TurtleGitMac.app/Contents'
            runtime = contents / 'Resources/TurtleGitRuntimes/Git'
            (runtime / 'bin').mkdir(parents=True)
            (runtime / 'libexec/git-core').mkdir(parents=True)
            (contents / 'Helpers').mkdir()
            (contents / 'MacOS').mkdir()
            physical = contents / 'MacOS/TurtleGitRuntime-Git-example-git'
            physical.write_bytes(b'owned relocation contract; never executed')
            (runtime / 'bin/git').symlink_to('../../../../MacOS/' + physical.name)
            (contents / 'Helpers/Git').symlink_to('../Resources/TurtleGitRuntimes/Git')
            logical = contents / 'Helpers/Git/bin/git'
            self.assertEqual(logical.resolve(), physical.resolve())
            selected = Path(SCOPE['native_git_invocation'](logical))
            self.assertEqual(selected, logical)
            self.assertNotEqual(selected, physical.resolve())
            self.assertEqual(selected.parent.parent.name, 'Git')
            self.assertEqual(selected.parent.parent / 'libexec/git-core', contents / 'Helpers/Git/libexec/git-core')

    def test_system_relative_and_unrelocated_versioned_engines_keep_selected_names(self):
        for git in [Path('/usr/bin/git'), Path('build/replay-test-git/2.37.1/bin/git'),
                    Path('build/replay-test-git/2.39.5/bin/git')]:
            with self.subTest(git=str(git)):
                self.assertEqual(SCOPE['native_git_invocation'](git), str(git.absolute()))

    def test_receiver_environment_uses_logical_helper_and_cleanup_keeps_physical_identity(self):
        updates = [node for node in ast.walk(TREE) if isinstance(node, ast.Call)
                   and isinstance(node.func, ast.Attribute) and node.func.attr == 'update']
        selected = [keyword.value for node in updates for keyword in node.keywords
                    if keyword.arg == 'TURTLEGIT_TEST_GIT']
        self.assertEqual(len(selected), 1)
        self.assertIsInstance(selected[0], ast.Call)
        self.assertEqual(ast.unparse(selected[0]), 'native_git_invocation(git)')
        # Executable ownership is deliberately physical; invocation is logical.
        approved = [node.value for node in ast.walk(TREE) if isinstance(node, ast.Assign)
                    and any(isinstance(target, ast.Name) and target.id == 'approved' for target in node.targets)]
        self.assertEqual(len(approved), 1)
        self.assertIn('git.resolve()', ast.unparse(approved[0]))


if __name__ == '__main__':
    unittest.main()
