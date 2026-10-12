#!/usr/bin/env python3
"""Build a universal adapter against pinned GitSVN headers, reusing its libraries."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git-runtime', type=Path, default=root / 'build/git-runtime/Git')
args = parser.parse_args()
runtime = args.git_runtime.resolve()
bucket = runtime / 'libexec/git-svn-runtime/arm64'
svn = bucket / 'Subversion/include/subversion-1'
apr = bucket / 'Dependencies/include/apr-1'
assert (svn / 'svn_diff.h').is_file() and (apr / 'apr.h').is_file(), 'Prepare the pinned Git/SVN runtime first.'
output = root / 'build/merge-diff-runtime/MergeDiff'
if output.exists():
    assert (output / 'provenance.json').is_file(), 'Refusing to replace an unrecognized runtime.'
output.mkdir(parents=True, exist_ok=True)
source = root / 'Sources/TurtleGitMergeDiff/main.c'
subprocess.run(['xcrun', 'clang', '-std=gnu17', '-O2', '-arch', 'arm64', '-arch', 'x86_64',
                '-mmacosx-version-min=13.0', '-I', str(svn), '-I', str(apr), str(source), '-o', str(output / 'merge-diff')], check=True)
reconstruction = output / 'Sources/build'
if (output / 'Sources').exists(): shutil.rmtree(output / 'Sources')
(reconstruction / 'Sources/TurtleGitMergeDiff').mkdir(parents=True)
(reconstruction / 'scripts').mkdir()
shutil.copy2(source, reconstruction / 'Sources/TurtleGitMergeDiff/main.c')
for name in ['build-merge-diff-runtime.py', 'validate-merge-diff-runtime.py']:
    shutil.copy2(root / 'scripts' / name, reconstruction / 'scripts' / name)
shutil.copy2(root / 'LICENSE', output / 'LICENSE')
shutil.copy2(root / 'LICENSE', reconstruction / 'LICENSE')
manifest = {'architectures': ['arm64', 'x86_64'], 'deployment_target': '13.0',
            'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
            'binary_sha256': hashlib.sha256((output / 'merge-diff').read_bytes()).hexdigest(),
            'svn_header_sha256': hashlib.sha256((svn / 'svn_diff.h').read_bytes()).hexdigest(),
            'subversion': json.loads((root / 'Configuration/GitSVNRuntime.json').read_text())['sources']['subversion'],
            'engine': 'Pinned Subversion diff2/diff3; bundled GitSVN libraries shared, not duplicated'}
(output / 'provenance.json').write_text(json.dumps(manifest, indent=2) + '\n')
subprocess.run(['python3', str(root / 'scripts/validate-merge-diff-runtime.py'), str(output)], check=True)
print(output)
