#!/usr/bin/env python3
"""Reuse byte-identical validated Debug runtimes; signed builds always rebuild."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
KITS = [
    ('lexilla', 'Lexilla'), ('issue-regex', 'IssueRegex'),
    ('merge-diff', 'MergeDiff'), ('graph-layout', 'GraphLayout'),
    ('editorconfig', 'EditorConfig'), ('openssh', 'OpenSSH'), ('putty', 'PuTTY'),
]

def fingerprint(paths, follow_roots=False):
    """Hash bytes, executable/permission bits, names and links, never mtimes.

    Do not follow directory aliases: their target is inventoried separately.
    Missing inputs are recorded, so adding/removing an optional kit invalidates.
    """
    digest = hashlib.sha256()
    def add(path, label):
        if not path.exists() and not path.is_symlink():
            record = [label, 'missing']
        else:
            mode = stat.S_IMODE(path.lstat().st_mode)
            if path.is_symlink(): record = [label, 'link', mode, os.readlink(path)]
            elif path.is_dir():
                record = [label, 'directory', mode]
            elif path.is_file():
                content = hashlib.sha256()
                with path.open('rb') as stream:
                    for block in iter(lambda: stream.read(1024 * 1024), b''): content.update(block)
                record = [label, 'file', mode, content.hexdigest()]
            else: raise RuntimeError('Unsupported runtime entry: ' + str(path))
        digest.update(json.dumps(record, separators=(',', ':')).encode() + b'\n')
        if path.is_dir() and not path.is_symlink():
            for child in sorted(path.iterdir(), key=lambda p: p.name): add(child, label + '/' + child.name)
    for label, path in sorted(paths.items()):
        path = Path(path); add(path, label)
        # copy2/copytree dereference an explicitly supplied source alias, unlike
        # symlinks inside a runtime tree. Include that source's actual bytes.
        if follow_roots and path.is_symlink(): add(path.resolve(), label + '/resolved-source')
    return digest.hexdigest()

def development_reuse(environment):
    return environment.get('CONFIGURATION') == 'Debug' and environment.get('CODE_SIGNING_ALLOWED') == 'NO'

def input_paths(root, products):
    paths = {'LICENSE': root/'LICENSE', 'NOTICE': root/'NOTICE',
             'configuration': root/'Configuration',
             'git-prompt': products/'TurtleGitGitAskpass', 'ssh-prompt': products/'TurtleGitSSHAskpass',
             'git-prompt-source': root/'Sources/TurtleGitGitAskpass',
             'ssh-prompt-source': root/'Sources/TurtleGitSSHAskpass',
             'prompt-model': root/'Sources/TurtleGitCore/GitAskpassPrompt.swift',
             'prompt-capture': root/'Sources/TurtleGitMac/DocumentationCapture.swift'}
    for name, directory in KITS + [('git', 'Git')]: paths['kit/' + name] = root/'build'/(name + '-runtime')/directory
    # Include validators, builders and shared runtime/relocation/downloader logic.
    # Runtime kits independently carry their own complete reconstruction sources.
    for pattern in ['*runtime*.py', '*askpass*.py', 'pinned_download.py', 'runtime_bundle_layout.py']:
        for path in (root/'scripts').glob(pattern): paths['script/' + path.name] = path
    return paths

def output_paths(app):
    contents = app/'Contents'
    paths = {'helper-aliases': contents/'Helpers',
             'runtime-data': contents/'Resources/TurtleGitRuntimes',
             'layout': contents/'Resources/runtime-layout.json',
             'runtime-libraries': contents/'Frameworks/TurtleGitRuntimeLibraries'}
    for path in (contents/'MacOS').glob('TurtleGitRuntime-*'): paths['native/' + path.name] = path
    return paths

def parent_structure(app):
    # Track container permissions without hashing the main app executable or
    # its changing frameworks. Never follow a replaced ancestor outside the app.
    result = {}
    for relative in ['', 'Contents', 'Contents/Resources', 'Contents/MacOS', 'Contents/Frameworks']:
        path = app/relative
        if path.is_symlink() or not path.is_dir(): raise RuntimeError('Unexpected runtime container: ' + str(path))
        result[relative] = stat.S_IMODE(path.lstat().st_mode)
    return result

def load_receipt(path):
    try:
        receipt = json.loads(path.read_text())
        return receipt if receipt.get('version') == 1 else None
    except (OSError, ValueError, TypeError, AttributeError): return None

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('products', type=Path)
    parser.add_argument('app', type=Path)
    parser.add_argument('receipt', type=Path)
    args = parser.parse_args()
    environment = os.environ.copy()
    reuse = development_reuse(environment)
    key = None
    if reuse:
        parents = parent_structure(args.app)
        key = fingerprint(input_paths(ROOT, args.products), follow_roots=True)
        receipt = load_receipt(args.receipt)
        context = {name: environment.get(name) for name in ['CONFIGURATION', 'CODE_SIGNING_ALLOWED', 'ARCHS', 'SDKROOT', 'DEVELOPER_DIR']}
        context['app'] = str(args.app.resolve())
        if receipt and receipt.get('inputs') == key and receipt.get('context') == context and receipt.get('parents') == parents:
            if ((args.app/'Contents/Resources/runtime-layout.json').is_file()
                and receipt.get('outputs') == fingerprint(output_paths(args.app))
                and fingerprint(input_paths(ROOT, args.products), follow_roots=True) == key):
                print('Reused byte-identical validated Debug runtimes; signed builds never use this receipt.')
                return
    # Never leave an earlier acceptance receipt after a failed embedding.
    args.receipt.unlink(missing_ok=True)
    def run(script, *arguments):
        subprocess.run(['/usr/bin/python3', str(ROOT/'scripts'/script), *map(str, arguments)], check=True)
    run('embed-git-askpass.py', args.products/'TurtleGitGitAskpass', args.app)
    run('embed-ssh-askpass.py', args.products/'TurtleGitSSHAskpass', args.app)
    for name, directory in KITS:
        run('embed-' + name + '-runtime.py', ROOT/'build'/(name + '-runtime')/directory, args.app)
    git = ROOT/'build/git-runtime/Git'
    if environment.get('CONFIGURATION') == 'AppStore' or git.is_dir(): run('embed-git-runtime.py', git, args.app)
    run('finalize-runtime-layout.py', args.app)
    if reuse:
        # Source kits must not change while the accepted output is produced.
        if fingerprint(input_paths(ROOT, args.products), follow_roots=True) != key: raise RuntimeError('Runtime inputs changed during embedding; rebuild.')
        receipt = {'version': 1, 'inputs': key, 'context': context, 'parents': parent_structure(args.app), 'outputs': fingerprint(output_paths(args.app))}
        args.receipt.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(mode='w', dir=args.receipt.parent, delete=False) as stream:
            temporary = Path(stream.name); json.dump(receipt, stream, indent=2); stream.write('\n')
        try: temporary.replace(args.receipt)
        finally: temporary.unlink(missing_ok=True)
        print('Recorded validated Debug runtime receipt after full embedding and layout audit.')

if __name__ == '__main__': main()
