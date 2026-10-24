#!/usr/bin/env python3
"""Native classic/modern comment review, mixed editable export and owned lifecycle."""
import argparse
import os
import posixpath
from pathlib import Path
import tempfile
from urllib.parse import unquote
import xml.etree.ElementTree as ET
import zipfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--only', choices=['review', 'lifecycle', 'capture'], action='append')
parser.add_argument('--capture-dir', type=Path)
parser.add_argument('--output-dir', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
generated = root / 'build/qa/presentation-comments-native-sources'
generated.mkdir(parents=True, exist_ok=True)

def verify_output(path):
    """Validate the editable graph with Python stdlib, independently of Core."""
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None, 'Comments output ZIP CRC failure'
        assert len(archive.namelist()) == len(set(archive.namelist())), 'Duplicate output members'
        parts = {name: archive.read(name) for name in archive.namelist()}
    parsed = {name: ET.fromstring(data) for name, data in parts.items() if name.endswith(('.xml', '.rels'))}
    for name, xml in parsed.items():
        if not name.endswith('.rels'):
            continue
        if name == '_rels/.rels':
            owner = ''
        else:
            components = name.split('/')
            assert len(components) >= 2 and components[-2] == '_rels', ('Invalid relationship part name', name)
            filename = components[-1].removesuffix('.rels')
            assert filename, ('Empty relationship owner', name)
            owner = '/'.join(components[:-2] + [filename])
            assert owner in parts, ('Missing relationship owner', name, owner)
        ids = set()
        for edge in xml:
            assert edge.attrib['Id'] not in ids, 'Duplicate relationship ID'
            ids.add(edge.attrib['Id'])
            if edge.attrib.get('TargetMode') == 'External':
                continue
            target = unquote(edge.attrib['Target'])
            resolved = posixpath.normpath(target.lstrip('/') if target.startswith('/') else posixpath.join(posixpath.dirname(owner), target))
            assert resolved in parts, (name, resolved)
    comments = [xml for name, xml in parsed.items() if name.startswith('ppt/comments/') and name.endswith('.xml')]
    assert comments, 'Editable output omitted comments'
    texts = [''.join(node.itertext()) for xml in comments for node in xml.iter() if node.tag.endswith('}text') or node.tag.endswith('}t')]
    assert set(texts) == {'New root', 'Base reply', 'Added comment'}, texts
    assert 'Unchanged context' not in texts, 'Deleted unchanged comment survived export'
    assert any('Alice' in str(xml.attrib) for root in parsed.values() for xml in root.iter()), 'Comment author lost'
    print('PASS: independent comments ZIP/XML, chosen text/deletion/authors and relationship graph', flush=True)

with tempfile.TemporaryDirectory(prefix='turtlegit-presentation-comments-') as temporary:
    directory = Path(temporary)
    main = generated / 'PresentationCommentsMain.swift'
    main.write_text('import AppKit\n@main struct PresentationCommentsMain { @MainActor static func main() async throws {\n'
                    'NSApp.setActivationPolicy(.prohibited)\n'
                    'switch ProcessInfo.processInfo.environment["TURTLEGIT_COMMENTS_CASE"]! {\n'
                    'case "review": try await PresentationCommentsVerification.review()\n'
                    'case "lifecycle": try await PresentationCommentsVerification.lifecycle()\n'
                    'case "capture": try await PresentationCommentsVerification.capturesOnly()\n'
                    'default: fatalError("Unknown comments case")\n}\n'
                    'print("PASS: native presentation comments completed")\n} }\n')
    receiver = build_receiver(root, [root / 'docs/qa/presentation-revision-native-2026-10-20.swift', root / 'docs/qa/presentation-comments-native-2026-10-24.swift', main], generated)
    for case in args.only or ['review', 'lifecycle']:
        private = directory / case
        private.mkdir(mode=0o700)
        repository = private / 'repository'; repository.mkdir(mode=0o700)
        home = private / 'home'; home.mkdir(mode=0o700)
        xdg = private / 'xdg'; xdg.mkdir(mode=0o700)
        private_tmp = private / 'temporary'; private_tmp.mkdir(mode=0o700)
        config = private / 'global.config'; config.write_text('')
        output = args.output_dir.resolve() if args.output_dir else private / 'outputs'
        output.mkdir(parents=True, exist_ok=True)
        env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
        env.update(GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0', CFFIXED_USER_HOME=str(home), XDG_CONFIG_HOME=str(xdg), TMPDIR=str(private_tmp), DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'), TURTLEGIT_COMMENTS_CASE=case, TURTLEGIT_COMMENTS_OUTPUT_DIR=str(output))
        if args.capture_dir and case in ['review', 'capture']:
            args.capture_dir.mkdir(parents=True, exist_ok=True)
            env['TURTLEGIT_COMMENTS_CAPTURE_DIR'] = str(args.capture_dir.resolve())
        print('Checking presentation comments ' + case, flush=True)
        result = run_receiver([str(receiver), str(repository), '/usr/bin/git'], cwd=root, env=env, capture_output=True, text=True, timeout_sample=private / 'timeout.sample.txt')
        print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
        if 'PASS: native presentation comments completed' not in result.stdout:
            raise SystemExit('Receiver exited before comments completion: ' + case)
        if case == 'review':
            verify_output(output / 'comments-classic.pptx')
            verify_output(output / 'comments-modern.pptx')
