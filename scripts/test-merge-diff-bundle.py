#!/usr/bin/env python3
"""Verify the embedded adapter loads only the app's shared Subversion runtime."""
from pathlib import Path
import argparse
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
parser.add_argument('--all-architectures', action='store_true')
args = parser.parse_args()
helper = args.app.resolve() / 'Contents/Helpers/MergeDiff/merge-diff'
runtime = args.app.resolve() / 'Contents/Helpers/Git'
prefixes = [['/usr/bin/arch', '-arm64'], ['/usr/bin/arch', '-x86_64']] if args.all_architectures else [[]]
with tempfile.TemporaryDirectory(prefix='TurtleGitMergeBundle-') as temporary:
    folder = Path(temporary)
    files = [folder / str(index) for index in range(3)]
    for file, text in zip(files, ['head\nbase\nlast', 'head\nmine\nlast', 'head\ntheirs\nlast']):
        file.write_text(''.join(line.encode().hex() + '\n' for line in text.splitlines(keepends=True)))
    for prefix in prefixes:
        output = subprocess.check_output(prefix + [str(helper), str(runtime), '3'] + list(map(str, files)), text=True, timeout=10)
        assert output == 'svn-diff\t1\t3\ncommon\t0\t1\t0\t1\t0\t1\nconflict\t1\t1\t1\t1\t1\t1\ncommon\t2\t1\t2\t1\t2\t1\n', output
        print('Embedded Subversion diff3 ranges and shared-library loading passed: ' + (' '.join(prefix) if prefix else 'native CPU'))
print('Owned helper processes exited; no application windows or repository writes.')
