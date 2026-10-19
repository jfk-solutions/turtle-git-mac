#!/usr/bin/env python3
"""Deliberately capture light/dark native Blame panes with WindowServer only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, default=Path('/usr/bin/git'))
parser.add_argument('--output', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
output = (args.output or root/'build/qa/blame-pane-captures-2026-10-19').absolute()
output.mkdir(parents=True, exist_ok=True)
if any((output/name).exists() for name in ('blame-panes-light.png', 'blame-panes-dark.png', 'capture.json')):
    raise SystemExit('Choose an empty output directory to preserve earlier capture evidence.')
sources = root/'build/qa/blame-pane-capture-native-sources'
sources.mkdir(parents=True, exist_ok=True)
receiver = build_receiver(root, [root/'docs/qa/blame-pane-capture-native-2026-10-19.swift'], sources)
with tempfile.TemporaryDirectory(prefix='turtlegit-blame-pane-capture-') as temporary:
    folder = Path(temporary)
    repository = folder/'repository'; repository.mkdir()
    private_temporary = folder/'temporary'; private_temporary.mkdir(mode=0o700)
    environment = dict(os.environ, TMPDIR=str(private_temporary)+'/', DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0', XDG_CONFIG_HOME=str(folder/'xdg'))
    for key in ('GIT_CONFIG_PARAMETERS', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR', 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_AUTHOR_DATE', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL', 'GIT_COMMITTER_DATE'):
        environment.pop(key, None)
    result = run_receiver([str(receiver), str(repository), str(args.git.absolute()), str(output)], cwd=root, env=environment, capture_output=True, text=True, timeout=120, timeout_sample=output/'timeout.sample.txt')
    (output/'receiver.stdout.txt').write_text(result.stdout)
    (output/'receiver.stderr.txt').write_text(result.stderr)
    print(result.stdout, end=''); print(result.stderr, end='')
    result.check_returncode()
    if 'PASS Blame pane compositor capture:' not in result.stdout:
        raise SystemExit('Capture receiver exited before native completion; no assets published.')
manifest_path = output/'capture.json'
manifest = json.loads(manifest_path.read_text())
for capture in manifest['captures']:
    path = Path(capture['path'])
    data = path.read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n' or data[12:16] != b'IHDR':
        raise SystemExit('WindowServer output is not an original PNG: ' + str(path))
    width, height = struct.unpack('>II', data[16:24])
    if (width, height) != (capture['width'], capture['height']):
        raise SystemExit('Captured dimensions disagree with native decoder: ' + str(path))
    capture.update(sha256=hashlib.sha256(data).hexdigest(), bytes=len(data))
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True)+'\n')
print(json.dumps(manifest, indent=2, sort_keys=True))
