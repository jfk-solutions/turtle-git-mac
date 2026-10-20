#!/usr/bin/env python3
"""Focused source GetCommit helper contracts, including raw encoded metadata."""
import argparse, base64, json, os, pathlib, subprocess, tempfile
from helper_architectures import execution_prefixes

PREFIX = b'TurtleGit SingleCommit v1:'
FIELDS = ['encoding', 'authorName', 'authorEmail', 'committerName', 'committerEmail', 'message']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', type=pathlib.Path, required=True)
    parser.add_argument('--git', default='/usr/bin/git')
    parser.add_argument('--all-architectures', action='store_true')
    args = parser.parse_args(); helper = args.helper.resolve()
    architectures = execution_prefixes(helper, args.all_architectures)
    for architecture in architectures:
        with tempfile.TemporaryDirectory(prefix='turtlegit-single-commit-') as temporary:
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
            (repo / 'file').write_bytes(b'original\n'); git('add', '--', 'file'); git('commit', '-m', 'Original')
            parent = git('rev-parse', 'HEAD').decode(); tree = git('rev-parse', 'HEAD^{tree}').decode()
            index = (repo / '.git/index').read_bytes()
            def commit(message, encoding=b'ISO-8859-1', author=b'J\xf6rg', email=b'jos\xe9@example.invalid', parents=None):
                links = [parent] if parents is None else parents
                data = b'tree ' + tree.encode() + b'\n' + b''.join(b'parent ' + value.encode() + b'\n' for value in links)
                data += b'author ' + author + b' <' + email + b'> -123 +0230\n'
                data += b'committer Ren\xe9 <committer@example.invalid> 42 -0345\n'
                if encoding is not None: data += b'encoding ' + encoding + b'\n'
                # Exercise signed timestamps without Git's creation-time fsck rejecting the raw fixture.
                return git('hash-object', '--literally', '-t', 'commit', '-w', '--stdin', input=data + b'\n' + message).decode()
            def request(revision, allow_tree=False, ok=True, directory=repo, value=None, extra_env=None):
                payload = value if value is not None else {'version': 1, 'revision': revision, 'allowTree': allow_tree}
                result = subprocess.run(architecture + [str(helper), '-C', str(directory), 'turtlegit-single-commit'],
                                        input=json.dumps(payload).encode(), env=dict(env, **(extra_env or {})), capture_output=True, timeout=45)
                assert len(result.stdout) <= 67_108_864
                frames = []
                for line in result.stdout.splitlines():
                    assert line.startswith(PREFIX) and len(line) <= 2_097_152
                    encoded = line[len(PREFIX):]; packet = base64.b64decode(encoded, validate=True)
                    assert base64.b64encode(packet) == encoded
                    frames.append(json.loads(packet))
                if not ok:
                    assert result.returncode != 0 and not any(row.get('kind') == 'end' for row in frames), (revision, result.stdout[:2048])
                    return None, None
                assert result.returncode == 0, result.stderr.decode(errors='replace')
                assert frames[0] == {'kind': 'header'} and frames[-1] == {'kind': 'end', 'count': len(frames) - 2}
                metadata = frames[1]
                if metadata['kind'] == 'tree':
                    assert metadata == {'kind': 'tree', 'oid': tree, 'objectType': 'tree'} and len(frames) == 3
                    return metadata, {}
                assert set(metadata) == {'kind', 'oid', 'objectType', 'tree', 'parents', 'authorTime', 'authorOffset', 'committerTime', 'committerOffset',
                                         'encodingBytes', 'authorNameBytes', 'authorEmailBytes', 'committerNameBytes', 'committerEmailBytes', 'messageBytes'}
                assert metadata['kind'] == 'commit' and metadata['objectType'] == 'commit'
                assert len(metadata['oid']) == 40 and metadata['tree'] == tree and len(metadata['parents']) <= 4096
                expected = [(field, metadata[field + 'Bytes']) for field in FIELDS if metadata[field + 'Bytes']]
                buffers = {field: bytearray() for field in FIELDS}; position = 0
                for frame in frames[2:-1]:
                    assert set(frame) == {'kind', 'field', 'data'} and frame['kind'] == 'bytes' and position < len(expected)
                    field, total = expected[position]; assert frame['field'] == field
                    block = base64.b64decode(frame['data'], validate=True)
                    assert base64.b64encode(block).decode() == frame['data'] and 0 < len(block) <= 524_288
                    buffers[field].extend(block); assert len(buffers[field]) <= total
                    if len(buffers[field]) == total: position += 1
                assert position == len(expected)
                assert all(len(buffers[field]) == (metadata[field + 'Bytes'] or 0) for field in FIELDS)
                return metadata, {field: bytes(data) for field, data in buffers.items()}
            message = b'  First line\r\ncontinuation in the subject paragraph\n\nBody: caf\xe9\n\n'
            legacy = commit(message); git('update-ref', 'refs/heads/legacy', legacy)
            metadata, raw = request('legacy')
            assert metadata['oid'] == legacy and metadata['parents'] == [parent]
            assert metadata['authorTime'] == -123 and metadata['authorOffset'] == 150
            assert metadata['committerTime'] == 42 and metadata['committerOffset'] == -225
            assert raw == {'encoding': b'ISO-8859-1', 'authorName': b'J\xf6rg', 'authorEmail': b'jos\xe9@example.invalid',
                           'committerName': b'Ren\xe9', 'committerEmail': b'committer@example.invalid', 'message': message}
            # Peeling accepts annotated/signed-style tags without claiming signature verification.
            signed = b'object ' + legacy.encode() + b'\ntype commit\ntag signed-style\ntagger Fixture <fixture@example.invalid> 42 +0000\n\nTag\n-----BEGIN PGP SIGNATURE-----\nfixture-not-a-real-signature\n-----END PGP SIGNATURE-----\n'
            signed_oid = git('hash-object', '-t', 'tag', '-w', '--stdin', input=signed).decode()
            git('update-ref', 'refs/tags/signed-style', signed_oid)
            nested = b'object ' + signed_oid.encode() + b'\ntype tag\ntag nested\ntagger Fixture <fixture@example.invalid> 42 +0000\n\nNested\n'
            nested_oid = git('hash-object', '-t', 'tag', '-w', '--stdin', input=nested).decode(); git('update-ref', 'refs/tags/nested', nested_oid)
            assert request('signed-style')[0]['oid'] == legacy and request('nested')[1]['message'] == message
            assert request(tree, allow_tree=True)[0]['objectType'] == 'tree'
            assert request('signed-style^{tree}', allow_tree=True)[0]['objectType'] == 'tree'
            request(tree, ok=False)
            tree_tag = b'object ' + tree.encode() + b'\ntype tree\ntag tree-tag\ntagger Fixture <fixture@example.invalid> 42 +0000\n\nTree tag\n'
            tree_tag_oid = git('hash-object', '-t', 'tag', '-w', '--stdin', input=tree_tag).decode(); git('update-ref', 'refs/tags/tree-tag', tree_tag_oid)
            request('tree-tag', allow_tree=True, ok=False)
            blob = git('hash-object', '-w', '--stdin', input=b'blob').decode(); request(blob, allow_tree=True, ok=False)
            # Empty/missing encoding remain distinct, and raw unknown descriptors are not rewritten.
            empty = commit(b'', encoding=None, parents=[])
            empty_meta, empty_raw = request(empty)
            assert empty_meta['encodingBytes'] is None and empty_meta['parents'] == [] and empty_raw['message'] == b''
            unknown = commit(b'raw\xff\n', encoding=b'not-a-real-encoding')
            assert request(unknown)[1]['encoding'] == b'not-a-real-encoding' and request(unknown)[1]['message'] == b'raw\xff\n'
            # Chunk boundaries cover identities as well as raw messages.
            large_name = b'N' * 524_289; large_message = b'M' * 1_100_000 + b'\n\n'
            chunked = commit(large_message, encoding=None, author=large_name)
            chunk_meta, chunk_raw = request(chunked)
            assert chunk_meta['authorNameBytes'] == len(large_name) and chunk_raw['authorName'] == large_name and chunk_raw['message'] == large_message
            too_large = commit(b'M' * 16_777_217); request(too_large, ok=False)
            too_large_name = commit(b'message', author=b'N' * 1_048_577); request(too_large_name, ok=False)
            too_many_parents = commit(b'parents', parents=[parent] * 4097); request(too_many_parents, ok=False)
            request('0' * 40, ok=False); request('HEAD', value={'version': 1, 'revision': 'HEAD', 'allowTree': 1}, ok=False)
            request('HEAD', value={'version': 1, 'revision': 'HEAD', 'allowTree': False, 'extra': True}, ok=False)
            request('HEAD', value={'version': True, 'revision': 'HEAD', 'allowTree': False}, ok=False)
            request('has\0nul', ok=False); request('r' * 1_048_577, ok=False)
            cancel = root / 'cancel'; cancel.write_bytes(b'cancelled')
            request('HEAD', ok=False, extra_env={'TURTLEGIT_REMOTE_PROMPT_CANCEL_FILE': str(cancel)})
            bare = root / 'bare.git'; git('clone', '--bare', '--no-hardlinks', repo, bare, cwd=root)
            assert request('legacy', directory=bare)[1]['message'] == message
            assert (repo / '.git/index').read_bytes() == index and git('rev-parse', 'HEAD').decode() == parent and (repo / 'file').read_bytes() == b'original\n'
            print('SingleCommit helper:', architecture[-1] if architecture else 'host', 'raw encoding/signatures/message/tag/tree/chunks/bounds/errors/bare passed', flush=True)

if __name__ == '__main__':
    main()
