#!/usr/bin/env python3
"""Run graph geometry through each actual built Core framework and embedded helper."""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
source = ROOT / 'docs/qa/graph-layout-built-2026-10-10.swift'
with tempfile.TemporaryDirectory(prefix='turtlegit-graph-built-') as temporary:
    for configuration, derived in [('Debug', 'build'), ('AppStore', 'build-store')]:
        app = ROOT / derived / 'Build/Products' / configuration / 'TurtleGitMac.app'
        frameworks = app / 'Contents/Frameworks'
        products = app.parent
        # Xcode strips Swift modules from copied app frameworks. Compile against
        # the build product's modules, then load the app's embedded binary.
        assert (products / 'TurtleGitCore.framework/TurtleGitCore').read_bytes() == (frameworks / 'TurtleGitCore.framework/TurtleGitCore').read_bytes()
        receiver = pathlib.Path(temporary) / ('graph-receiver-' + configuration)
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(source),
                        '-F', str(products), '-I', str(products), '-framework', 'TurtleGitCore',
                        '-framework', 'TurtleGitSMTP', '-Xlinker', '-rpath', '-Xlinker', str(frameworks),
                        '-o', str(receiver)], check=True)
        result = subprocess.run([str(receiver), str(app), configuration], capture_output=True, text=True, timeout=30, check=True)
        print(result.stdout, end='')
        if result.stderr:
            print(result.stderr, end='')
        assert 'PASS: '+configuration in result.stdout
print('Built app framework receivers passed; disposable executables removed. No app windows were launched.')
