#!/usr/bin/env python3
"""Grouped native nested PowerPoint revision decisions and editable export lifecycle."""
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

def verify_output(path):
    """Validate the editable graph with Python stdlib, independently of Core."""
    p = '{http://schemas.openxmlformats.org/presentationml/2006/main}'
    a = '{http://schemas.openxmlformats.org/drawingml/2006/main}'
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None, 'Group output ZIP CRC failure'
        assert len(archive.namelist()) == len(set(archive.namelist())), 'Duplicate output members'
        parts = {name: archive.read(name) for name in archive.namelist()}
    parsed = {name: ET.fromstring(data) for name, data in parts.items() if name.endswith(('.xml', '.rels'))}
    for name, xml in parsed.items():
        if not name.endswith('.rels'):
            continue
        owner = '' if name == '_rels/.rels' else name.replace('/_rels/', '/').removesuffix('.rels')
        ids = set()
        for edge in xml:
            assert edge.attrib['Id'] not in ids, 'Duplicate relationship ID'
            ids.add(edge.attrib['Id'])
            if edge.attrib.get('TargetMode') == 'External':
                continue
            target = unquote(edge.attrib['Target'])
            resolved = posixpath.normpath(target.lstrip('/') if target.startswith('/') else posixpath.join(posixpath.dirname(owner), target))
            assert resolved in parts, (name, resolved)
    slide = parsed['ppt/slides/slide1.xml']
    groups = list(slide.iter(p + 'grpSp'))
    assert len(groups) == 2, 'Editable output flattened nested groups'
    def shape_name(shape):
        return next(shape.iter(p + 'cNvPr')).attrib['name']
    outer = next(group for group in groups if shape_name(group) == 'Outer group')
    inner = next(group for group in outer if group.tag == p + 'grpSp')
    assert shape_name(inner) == 'Inner group', 'Lost nested group parent'
    assert [shape_name(child) for child in inner if child.tag == p + 'sp'] == ['Beta', 'Alpha'], 'Wrong nested stacking order'
    texts = {shape_name(shape): ''.join(node.text or '' for node in shape.iter(a + 't')) for shape in slide.iter(p + 'sp')}
    assert texts == {'Alpha': 'New Alpha', 'Beta': 'Base Beta', 'Deleted leaf': 'Retained deleted child', 'Added leaf': 'Accepted added child'}, texts
    identities = [int(node.attrib['id']) for node in slide.iter(p + 'cNvPr')]
    assert len(identities) == len(set(identities)), 'Colliding nested output shape IDs'
    assert parsed['ppt/presentation.xml'].find(p + 'sldMasterIdLst') is not None
    assert 'ppt/slideMasters/master.xml' in parts and 'ppt/slideLayouts/layout.xml' in parts and 'ppt/theme/theme.xml' in parts, 'Lost slide dependency closure'
    print('PASS: independent group ZIP/XML, child decisions/order, unique IDs and editable dependency graph', flush=True)

with tempfile.TemporaryDirectory(prefix='turtlegit-presentation-groups-') as temporary:
    directory = Path(temporary)
    main = directory / 'PresentationGroupReviewMain.swift'
    main.write_text('import AppKit\n@main struct PresentationGroupReviewMain { @MainActor static func main() async throws {\n'
                    'NSApp.setActivationPolicy(.prohibited)\n'
                    'switch ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_CASE"]! {\n'
                    'case "review": try await PresentationGroupReviewVerification.review()\n'
                    'case "lifecycle": try await PresentationGroupReviewVerification.lifecycle()\n'
                    'case "capture": try await PresentationGroupReviewVerification.capturesOnly()\n'
                    'default: fatalError("Unknown group review case")\n}\n'
                    'print("PASS: native presentation group review completed")\n} }\n')
    receiver = build_receiver(root, [root / 'docs/qa/presentation-revision-native-2026-10-20.swift', root / 'docs/qa/presentation-group-review-native-2026-10-20.swift', main], directory)
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
        env.update(GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0', CFFIXED_USER_HOME=str(home), XDG_CONFIG_HOME=str(xdg), TMPDIR=str(private_tmp), DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'), TURTLEGIT_GROUP_CASE=case, TURTLEGIT_GROUP_OUTPUT_DIR=str(output))
        if args.capture_dir and case in ['review', 'capture']:
            args.capture_dir.mkdir(parents=True, exist_ok=True)
            env['TURTLEGIT_GROUP_CAPTURE_DIR'] = str(args.capture_dir.resolve())
        print('Checking presentation groups ' + case, flush=True)
        result = run_receiver([str(receiver), str(repository), '/usr/bin/git'], cwd=root, env=env, capture_output=True, text=True, timeout_sample=private / 'timeout.sample.txt')
        print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
        if 'PASS: native presentation group review completed' not in result.stdout:
            raise SystemExit('Receiver exited before group review completion: ' + case)
        if case == 'review':
            verify_output(output / 'group-mixed.pptx')
