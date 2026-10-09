#!/usr/bin/env python3
"""Verify packaged Git's SSH lookup through the built Core, without a connection."""
import argparse
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app',type=Path,default=ROOT/'build-store/Build/Products/AppStore/TurtleGitMac.app')
args = parser.parse_args(); app = args.app.resolve()
frameworks = app/'Contents/Frameworks'
# Xcode strips module metadata from embedded distribution frameworks. Compile
# against the matching build product, then load the app's embedded framework.
products = app.parent
pin = json.loads((ROOT/'Configuration/OpenSSHRuntime.json').read_text())
with tempfile.TemporaryDirectory(prefix='tg-git-ssh-native-') as temporary:
    root = Path(temporary); executable = root/'receiver'
    subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','5','-target',platform.machine()+'-apple-macos13.0','-I',products,'-F',products,ROOT/'docs/qa/git-ssh-runtime-2026-10-10.swift','-framework','TurtleGitCore','-o',executable],check=True)
    environment = os.environ.copy(); environment['DYLD_FRAMEWORK_PATH'] = str(frameworks)
    subprocess.run([executable,app,root,pin['openssh']['version'],pin['openssl']['version']],env=environment,check=True,timeout=30)
assert not Path(temporary).exists()
