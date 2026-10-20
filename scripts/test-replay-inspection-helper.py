#!/usr/bin/env python3
"""Focused pinned helper readiness/conflict primitives; no full transport rerun."""
import argparse, base64, json, os, pathlib, subprocess, tempfile
from helper_architectures import execution_prefixes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', type=pathlib.Path, required=True)
    parser.add_argument('--git', default='/usr/bin/git')
    parser.add_argument('--all-architectures', action='store_true')
    args = parser.parse_args()
    helper = args.helper.resolve()
    prefixes = execution_prefixes(helper, args.all_architectures)
    for prefix in prefixes:
        with tempfile.TemporaryDirectory(prefix='turtlegit-replay-inspection-') as temporary:
            root = pathlib.Path(temporary); home = root / 'home'; home.mkdir()
            env = {key: value for key, value in os.environ.items() if not key.startswith(('GIT_', 'TURTLEGIT_'))}
            env.update(HOME=str(home), XDG_CONFIG_HOME=str(home / 'xdg'), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
                       GIT_TERMINAL_PROMPT='0', GIT_AUTHOR_NAME='Fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
                       GIT_COMMITTER_NAME='Fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid')
            repo = root / 'repo'
            def git(*values, cwd=repo, input=None):
                result = subprocess.run([args.git, *map(str, values)], cwd=cwd, env=env, input=input, capture_output=True, timeout=30)
                assert result.returncode == 0, result.stderr.decode(errors='replace')
                return result.stdout.strip()
            git('init', '-b', 'main', repo, cwd=root)
            def request(verb, value, ok=True, directory=repo, extra_env=None):
                result = subprocess.run(prefix + [str(helper), '-C', str(directory), verb], input=json.dumps(value, ensure_ascii=True).encode(),
                                        env=dict(env, **(extra_env or {})), capture_output=True, timeout=30)
                frames = []
                assert len(result.stdout) <= 67_108_864
                for line in result.stdout.splitlines():
                    assert line.startswith(b'TurtleGit Inspection v1:') and len(line) <= 2_097_152
                    encoded = line[len(b'TurtleGit Inspection v1:'):]
                    packet = base64.b64decode(encoded, validate=True)
                    assert base64.b64encode(packet) == encoded
                    frames.append(json.loads(packet))
                if not ok:
                    assert result.returncode != 0 and not any(row['kind'] == 'end' for row in frames), (verb, result.stdout)
                    return []
                assert result.returncode == 0, result.stderr.decode(errors='replace')
                assert frames[0]['kind'] == 'header' and frames[-1] == {'kind': 'end', 'count': len(frames) - 2}
                return frames[1:-1]
            def clean(staged=False):
                rows = request('turtlegit-check-clean', {'version': 1, 'stagedOK': staged})
                assert len(rows) == 1 and rows[0]['kind'] == 'clean' and type(rows[0]['clean']) is bool
                return rows[0]['clean']
            def conflicts():
                rows = request('turtlegit-check-conflicts', {'version': 1})
                assert len(rows) == 1 and rows[0]['kind'] == 'conflicts' and type(rows[0]['conflicts']) is bool
                return rows[0]['conflicts']
            # Source explicitly calls an unborn repository unclean.
            assert not clean() and not clean(True) and not conflicts()
            (repo / 'file').write_bytes(b'first\n'); git('add', '--', 'file'); git('commit', '-m', 'First')
            first = git('rev-parse', 'HEAD').decode()
            (repo / 'file').write_bytes(b'second\n'); git('commit', '-am', 'Second')
            head = git('rev-parse', 'HEAD').decode()
            tree = git('rev-parse', 'HEAD^{tree}').decode()
            divergent = git('commit-tree', tree, '-p', first, input=b'Divergent\n').decode()
            unrelated = git('commit-tree', tree, input=b'Unrelated\n').decode()
            for start, end, base, fast in [(first, head, first, True), (head, first, first, False), (head, head, head, True),
                                            (head, divergent, first, False), (head, unrelated, None, False)]:
                rows = request('turtlegit-merge-base', {'version': 1, 'from': start, 'to': end})
                assert rows == [{'kind': 'mergeBase', 'base': base, 'fastForward': fast}], rows
            assert clean() and clean(True) and not conflicts()
            (repo / 'untracked').write_bytes(b'untracked\n')
            (repo / '.git/info/exclude').write_text('ignored\n'); (repo / 'ignored').write_bytes(b'ignored\n')
            assert clean() and clean(True), 'Untracked/ignored files widened source clean predicate'
            (repo / 'file').write_bytes(b'staged\n'); git('add', '--', 'file')
            assert not clean() and clean(True), 'stagedOK failed to ignore staged-only change'
            (repo / 'file').write_bytes(b'unstaged\n')
            assert not clean() and not clean(True)
            git('reset', '--hard', head)
            # An actual initialized dirty submodule is excluded by the source flags.
            module_source = root / 'module-source'; git('init', '-b', 'main', module_source, cwd=root)
            (module_source / 'module-file').write_bytes(b'module\n'); git('add', '--', 'module-file', cwd=module_source); git('commit', '-m', 'Module', cwd=module_source)
            git('-c', 'protocol.file.allow=always', 'submodule', 'add', module_source, 'module'); git('commit', '-am', 'Submodule')
            (repo / 'module/module-file').write_bytes(b'dirty module\n')
            assert clean() and clean(True), 'Dirty submodule widened source clean predicate'
            regular = git('hash-object', '-w', '--stdin', input=b'ancestor\n').decode()
            binary = git('hash-object', '-w', '--stdin', input=b'\x00\xff\x01').decode()
            link = git('hash-object', '-w', '--stdin', input=b'../literal-target').decode()
            literal = 'tab\tline\nquote" percent% é.txt'
            rows_spec = [(literal, [(1, '100644', regular), (2, '100755', binary), (3, '120000', link)]),
                         ('deleted-side', [(1, '100644', regular), (2, '100644', binary)]),
                         ('gitlink', [(1, '160000', first), (3, '160000', head)])]
            packet = b''.join(f'{mode} {oid} {stage}\t'.encode() + path.encode() + b'\0'
                              for path, stages in rows_spec for stage, mode, oid in stages)
            git('update-index', '-z', '--index-info', input=packet)
            assert conflicts() and not clean() and not clean(True)
            paths = [path for path, _ in rows_spec] + ['not-conflicted']
            inspected = request('turtlegit-conflict-info', {'version': 1, 'paths': paths})
            expected = [{'kind': 'conflict', 'path': path,
                         'stages': [{'number': number, 'mode': int(mode, 8), 'oid': oid} for number, mode, oid in stages]}
                        for path, stages in rows_spec] + [{'kind': 'conflict', 'path': 'not-conflicted', 'stages': []}]
            assert inspected == expected, (inspected, expected)
            assert request('turtlegit-conflict-info', {'version': 1, 'paths': []}) == []
            # Each public decision rejects corrupt index state instead of claiming clean/no conflicts.
            index = repo / '.git/index'; saved = index.read_bytes(); index.write_bytes(b'corrupt index\n')
            try:
                request('turtlegit-check-conflicts', {'version': 1}, ok=False)
                request('turtlegit-check-clean', {'version': 1, 'stagedOK': False}, ok=False)
                request('turtlegit-conflict-info', {'version': 1, 'paths': paths}, ok=False)
            finally:
                index.write_bytes(saved)
            assert conflicts()
            request('turtlegit-conflict-info', {'version': 1, 'paths': ['../escape']}, ok=False)
            request('turtlegit-conflict-info', {'version': 1, 'paths': [literal, literal]}, ok=False)
            request('turtlegit-conflict-info', {'version': 1, 'paths': ['has\0nul']}, ok=False)
            request('turtlegit-check-clean', {'version': 1, 'stagedOK': 1}, ok=False)
            request('turtlegit-check-conflicts', {'version': 1, 'extra': True}, ok=False)
            request('turtlegit-merge-base', {'version': 1, 'from': head[:-1], 'to': first}, ok=False)
            request('turtlegit-merge-base', {'version': 1, 'from': regular, 'to': first}, ok=False)
            marker = root / 'cancel'; marker.write_bytes(b'cancelled\n')
            request('turtlegit-conflict-info', {'version': 1, 'paths': paths}, ok=False,
                    extra_env={'TURTLEGIT_REMOTE_PROMPT_CANCEL_FILE': str(marker)})
            assert index.read_bytes() == saved and (repo / 'file').read_bytes() == b'second\n'
            print('Replay inspection helper:', prefix[-1] if prefix else 'host', 'merge-base/clean/stagedOK/submodule/conflicts/stages/errors/cancel passed', flush=True)

if __name__ == '__main__':
    main()
