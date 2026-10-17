"""Bind local distribution candidates to measured repository inputs and bundle bytes."""
import hashlib
import json
from pathlib import Path
import subprocess
from distribution_archive import file_inventory

INPUT_PATHS = ('Sources', 'Configuration', 'TurtleGitMac.xcodeproj', 'Package.swift',
               'Package.resolved', 'LICENSE', 'NOTICE', 'scripts')
SCHEMA = 'TurtleGitDistributionInputsV1'


def digest_file(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def source_inputs(root):
    root = Path(root).resolve(strict=True)
    def git(*arguments):
        return subprocess.check_output(['git', '-C', str(root), *arguments])
    names = git('ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', *INPUT_PATHS)
    records = {}
    for name in sorted(set(names.decode('utf-8').split('\0')) - {''}):
        path = root / name
        if path.is_symlink():
            resolved = path.resolve(strict=True)
            if not resolved.is_relative_to(root) or not resolved.is_file():
                raise ValueError('Build input alias must reference a regular workspace file: ' + name)
            records[name] = {'kind': 'symlink', 'target': str(path.readlink()),
                             'referent_sha256': digest_file(resolved),
                             'referent_mode': oct(resolved.stat().st_mode & 0o777)}
        elif path.is_file():
            records[name] = {'kind': 'file', 'sha256': digest_file(path),
                             'mode': oct(path.stat().st_mode & 0o777)}
        elif not path.exists():
            records[name] = {'kind': 'missing'}
        else:
            raise ValueError('Unsupported distribution input: ' + name)
    encoded = json.dumps(records, sort_keys=True, separators=(',', ':')).encode('utf-8')
    return {'schema': SCHEMA, 'git_head_at_measurement': git('rev-parse', 'HEAD').decode().strip(),
            'dirty_inputs': bool(git('status', '--porcelain', '--untracked-files=all', '--', *INPUT_PATHS)),
            'paths': list(INPUT_PATHS), 'files': records,
            'sha256': hashlib.sha256(encoded).hexdigest()}


def require_same_inputs(expected, actual):
    if not isinstance(expected, dict) or expected.get('schema') != SCHEMA:
        raise ValueError('Rebuild the candidate to establish repository input provenance.')
    if expected.get('paths') != list(INPUT_PATHS) or expected.get('files') != actual['files'] or expected.get('sha256') != actual['sha256']:
        raise ValueError('Repository build inputs changed since the candidate build; rebuild it.')
    # A docs-only commit may move HEAD without changing any measured build input.
    # Keep both revisions explicit instead of relabelling the original build.


def require_same_bundle(expected, app):
    if not isinstance(expected, dict) or not expected:
        raise ValueError('Rebuild the candidate to establish complete bundle provenance.')
    actual = file_inventory(app)
    if actual != expected:
        changed = sorted(name for name in set(actual) | set(expected) if actual.get(name) != expected.get(name))
        raise ValueError('Candidate bundle changed since its audit: ' + ', '.join(changed[:8]))
    return actual


def verify_candidate(audit, root, app):
    current = source_inputs(root)
    require_same_inputs(audit.get('build_inputs'), current)
    require_same_bundle(audit.get('bundle_files'), app)
    return current
