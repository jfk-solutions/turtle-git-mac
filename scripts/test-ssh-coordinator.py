#!/usr/bin/env python3
"""Hidden native SSH coordinator and shipping transport fixtures; no SSH server."""
import argparse
import os
from pathlib import Path
import platform
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
products = root/'build/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='tg-ssh-native-') as temporary:
    directory = Path(temporary)
    app = root/'Sources/TurtleGitMac/TurtleGitMacApp.swift'
    copy = directory/app.name; copy.write_text(app.read_text().replace('@main struct','struct',1))
    sources = sorted(str(p) for p in (root/'Sources/TurtleGitMac').glob('*.swift') if p != app)
    executable = directory/'ssh-coordinator-native-receiver'
    subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','5','-target',platform.machine()+'-apple-macos13.0','-I',str(products),'-F',str(products),*sources,str(copy),str(root/'docs/qa/ssh-coordinator-native-2026-10-09.swift'),'-framework','TurtleGitCore','-o',str(executable)],cwd=root,check=True)
    environment = os.environ.copy(); environment['DYLD_FRAMEWORK_PATH'] = str(products)
    helper = products/'TurtleGitMac.app/Contents/Helpers/SSHAskpass/TurtleGitSSHAskpass'
    for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture = directory/str(index); fixture.mkdir(mode=0o700)
        subprocess.run([str(executable),str(fixture),str(git.resolve()),str(helper)],cwd=root,env=environment,check=True)
