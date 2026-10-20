#!/usr/bin/env python3
"""Focused actual-helper local reference contracts; no transport/full runtime rerun."""
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
        with tempfile.TemporaryDirectory(prefix='turtlegit-local-refs-') as temporary:
            root = pathlib.Path(temporary)
            home = root / 'home'; home.mkdir()
            env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / 'xdg'), GIT_CONFIG_NOSYSTEM='1',
                       GIT_CONFIG_GLOBAL='/dev/null', GIT_TERMINAL_PROMPT='0', GIT_AUTHOR_NAME='Fixture',
                       GIT_AUTHOR_EMAIL='fixture@example.invalid', GIT_COMMITTER_NAME='Fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid')
            for key in list(env):
                if key.startswith(('GIT_CONFIG_KEY_', 'GIT_CONFIG_VALUE_', 'TURTLEGIT_')) or key in ['GIT_CONFIG_PARAMETERS', 'GIT_CONFIG_COUNT', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE']:
                    env.pop(key, None)
            repo = root / 'repo'
            def git(*values, cwd=repo, input=None, ok=True):
                result = subprocess.run([args.git, *map(str, values)], cwd=cwd, env=env, input=input, capture_output=True, timeout=20)
                if ok: assert result.returncode == 0, result.stderr.decode(errors='replace')
                return result.stdout.strip()
            git('init', '-b', 'main', repo, cwd=root)
            (repo / 'file').write_text('first\n')
            git('add', '--', 'file'); git('commit', '-m', 'First')
            first = git('rev-parse', 'HEAD').decode()
            (repo / 'file').write_text('second\n'); git('commit', '-am', 'Second')
            head = git('rev-parse', 'HEAD').decode()
            git('branch', 'side', first)
            git('update-ref', 'refs/remotes/origin/main', head)
            git('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main')
            git('tag', '-a', 'outer', '-m', 'Annotated subject\n\nBody', head)
            tag = git('rev-parse', 'refs/tags/outer').decode()
            git('-c', 'advice.nestedTag=false', 'tag', '-a', 'nested', '-m', 'Nested', 'outer')
            tree = git('rev-parse', 'HEAD^{tree}').decode()
            blob = git('hash-object', '-w', '--stdin', input=b'blob\n').decode()
            git('update-ref', 'refs/custom/tree', tree); git('update-ref', 'refs/custom/blob', blob)
            raw_index = (repo / '.git/index').read_bytes()
            def request(verb, value, ok=True, directory=repo):
                result = subprocess.run(prefix + [str(helper), '-C', str(directory), verb], input=json.dumps(value).encode(), env=env,
                                        capture_output=True, timeout=30)
                if not ok:
                    assert result.returncode != 0, (verb, result.stdout)
                    assert not any(json.loads(base64.b64decode(line.split(b':', 1)[1]))['kind'] == 'end'
                                   for line in result.stdout.splitlines() if line.startswith(b'TurtleGit LocalRefs v1:'))
                    return []
                assert result.returncode == 0, result.stderr.decode(errors='replace')
                assert len(result.stdout) <= 67_108_864
                rows = []
                for line in result.stdout.splitlines():
                    assert line.startswith(b'TurtleGit LocalRefs v1:') and len(line) <= 2_097_152
                    encoded = line[len(b'TurtleGit LocalRefs v1:'):]
                    decoded = base64.b64decode(encoded, validate=True)
                    assert base64.b64encode(decoded) == encoded
                    rows.append(json.loads(decoded))
                assert rows[0]['kind'] == 'header' and rows[-1] == {'kind': 'end', 'count': len(rows) - 2}
                return rows[1:-1]
            rows = request('turtlegit-local-refs', {'version': 1, 'scope': 'all'})
            refs = {row['name']: row for row in rows}
            assert refs['refs/tags/outer']['oid'] == tag and refs['refs/tags/outer']['subject'] == 'Annotated subject'
            assert refs['refs/tags/outer']['authorName'] == 'Fixture' and refs['refs/tags/outer']['authorTime'] is not None
            assert refs['refs/custom/tree']['objectType'] == 'tree' and refs['refs/custom/tree']['authorTime'] is None
            assert refs['refs/custom/blob']['oid'] == blob and refs['refs/custom/blob']['subject'] == ''
            assert refs['refs/remotes/origin/HEAD']['symbolicTarget'] == 'refs/remotes/origin/main'
            contains = request('turtlegit-containing-refs', {'version': 1, 'revision': first, 'includeTags': True, 'includeLocal': True, 'includeRemote': True})
            names = {row['name'] for row in contains}
            assert {'refs/heads/main', 'refs/heads/side', 'refs/tags/nested', 'refs/remotes/origin/HEAD'} <= names
            tags = request('turtlegit-containing-refs', {'version': 1, 'revision': head, 'includeTags': True, 'includeLocal': False, 'includeRemote': False})
            assert {row['name'] for row in tags} == {'refs/tags/outer', 'refs/tags/nested'}
            # Names-only must tolerate broken aliases that metadata resolution rejects.
            git('symbolic-ref', 'refs/remotes/broken/HEAD', 'refs/remotes/broken/missing')
            names = request('turtlegit-ref-names', {'version': 1})
            assert 'refs/remotes/broken/HEAD' in {row['name'] for row in names}
            request('turtlegit-local-refs', {'version': 1, 'scope': 'all'}, ok=False)
            heads = request('turtlegit-local-refs', {'version': 1, 'scope': 'heads'})
            assert {row['name'] for row in heads} == {'refs/heads/main', 'refs/heads/side'}
            # Stale direct and changed symbolic identity cannot remove either ref.
            delete = lambda name, oid, target=None: {'version': 1, 'reference': name, 'expectedOID': oid, 'expectedSymbolicTarget': target}
            request('turtlegit-delete-local-ref', delete('refs/heads/side', head), ok=False)
            request('turtlegit-delete-local-ref', delete('refs/remotes/origin/HEAD', head), ok=False)
            assert git('rev-parse', 'refs/heads/side').decode() == first
            request('turtlegit-delete-local-ref', delete('refs/remotes/origin/HEAD', head, 'refs/remotes/origin/main'))
            assert git('rev-parse', 'refs/remotes/origin/main').decode() == head
            assert git('symbolic-ref', '-q', 'refs/remotes/origin/HEAD', ok=False) == b''
            request('turtlegit-delete-local-ref', delete('refs/heads/main', head), ok=False)
            # A locked config refuses the whole branch removal before ref commit.
            config_lock = repo / '.git/config.lock'; config_lock.write_bytes(b'owned config lock\n')
            request('turtlegit-delete-local-ref', delete('refs/heads/side', first), ok=False)
            assert git('rev-parse', 'refs/heads/side').decode() == first and config_lock.read_bytes() == b'owned config lock\n'
            config_lock.unlink()
            git('config', 'branch.side.remote', 'origin'); git('config', '--add', 'branch.side.custom', 'one'); git('config', '--add', 'branch.side.custom', 'two')
            git('config', 'branch.sibling.remote', 'keep')
            request('turtlegit-delete-local-ref', delete('refs/heads/side', first))
            assert git('config', '--get-regexp', r'^branch\.side\.', ok=False) == b''
            assert git('config', '--get', 'branch.sibling.remote') == b'keep'
            git('pack-refs', '--all', '--prune')
            request('turtlegit-delete-local-ref', delete('refs/tags/outer', head), ok=False)
            request('turtlegit-delete-local-ref', delete('refs/tags/outer', tag))
            request('turtlegit-delete-local-ref', delete('refs/custom/blob', blob))
            # Linked worktree branch refusal uses the actual pinned library guard.
            linked = root / 'linked'; git('worktree', 'add', '-b', 'held', linked, head)
            request('turtlegit-delete-local-ref', delete('refs/heads/held', head), ok=False)
            git('worktree', 'remove', linked)
            git('branch', 'locked', first)
            lock = repo / '.git/refs/heads/locked.lock'; lock.write_bytes(b'fixture lock\n')
            request('turtlegit-delete-local-ref', delete('refs/heads/locked', first), ok=False)
            assert lock.read_bytes() == b'fixture lock\n' and git('rev-parse', 'refs/heads/locked').decode() == first
            lock.unlink()
            request('turtlegit-local-refs', {'version': 1, 'scope': 'heads', 'extra': True}, ok=False)
            request('turtlegit-containing-refs', {'version': 1, 'revision': head, 'includeTags': 1, 'includeLocal': True, 'includeRemote': True}, ok=False)
            request('turtlegit-delete-local-ref', delete('refs/heads/locked', '0' * 39), ok=False)
            bare = root / 'bare.git'; git('init', '--bare', bare, cwd=root)
            assert request('turtlegit-local-refs', {'version': 1, 'scope': 'all'}, directory=bare) == []
            git('update-ref', 'refs/heads/main', head, cwd=repo)
            # The bare repository has independent object storage, populated by Git.
            git('push', bare, 'refs/heads/main:refs/heads/imported')
            bare_rows = request('turtlegit-local-refs', {'version': 1, 'scope': 'heads'}, directory=bare)
            assert len(bare_rows) == 1 and bare_rows[0]['oid'] == head
            request('turtlegit-delete-local-ref', delete('refs/heads/imported', head), directory=bare)
            assert (repo / '.git/index').read_bytes() == raw_index and (repo / 'file').read_text() == 'second\n'
            print('LocalRefs helper:', prefix[-1] if prefix else 'host', 'inventory/contains/names/CAS/alias/config/worktree/lock/malformed passed', flush=True)

if __name__ == '__main__':
    main()
