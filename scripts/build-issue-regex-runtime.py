#!/usr/bin/env python3
"""Build the native C++ issue matcher with Windows UTF-16 string semantics."""
import hashlib
import json
import pathlib
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
target = ROOT / 'build/issue-regex-runtime/IssueRegex'
if target.exists() and not (target / 'provenance.json').exists():
    raise RuntimeError('Refusing to replace an unrecognized IssueRegex runtime')
target.mkdir(parents=True, exist_ok=True)
source = ROOT / 'Sources/TurtleGitIssueRegex/main.cpp'
subprocess.run(['xcrun', 'clang++', '-std=c++17', '-O2', '-arch', 'arm64', '-arch', 'x86_64',
                '-mmacosx-version-min=13.0', source, '-o', target / 'issue-regex'], check=True)
rebuild = target / 'Sources/build'
if (target / 'Sources').exists():
    shutil.rmtree(target / 'Sources')
(rebuild / 'Sources/TurtleGitIssueRegex').mkdir(parents=True, exist_ok=True)
(rebuild / 'scripts').mkdir(exist_ok=True)
shutil.copy2(source, rebuild / 'Sources/TurtleGitIssueRegex/main.cpp')
shutil.copy2(ROOT / 'LICENSE', target / 'LICENSE')
shutil.copy2(ROOT / 'LICENSE', rebuild / 'LICENSE')
shutil.copy2(__file__, rebuild / 'scripts/build-issue-regex-runtime.py')
shutil.copy2(ROOT / 'scripts/validate-issue-regex-runtime.py', rebuild / 'scripts/validate-issue-regex-runtime.py')
manifest = {'architectures': ['arm64', 'x86_64'], 'deployment_target': '13.0',
            'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
            'binary_sha256': hashlib.sha256((target / 'issue-regex').read_bytes()).hexdigest(),
            'engine': 'C++ std::wregex ECMAScript, one UTF-16 unit per wchar_t'}
(target / 'provenance.json').write_text(json.dumps(manifest, indent=2) + '\n')
subprocess.run(['python3', ROOT / 'scripts/validate-issue-regex-runtime.py', target], check=True)
print(target)
