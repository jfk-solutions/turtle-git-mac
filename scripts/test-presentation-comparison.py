#!/usr/bin/env python3
"""Grouped native PowerPoint automation contract, routing, review and lifecycle."""
import argparse
import os
import posixpath
import xml.etree.ElementTree as ET
import zipfile
from urllib.parse import unquote
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--captures',type=Path)
parser.add_argument('--only',choices=['automation','review','routing','lifecycle','revision','revision-automation','result'],action='append')
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--output-dir',type=Path)
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
sources=root/'build/qa/presentation-comparison-sources'
sources.mkdir(parents=True,exist_ok=True)
receiver=build_receiver(root,[root/'docs/qa/presentation-comparison-native-2026-10-20.swift',root/'docs/qa/powerpoint-automation-native-2026-10-20.swift',root/'docs/qa/presentation-revision-native-2026-10-20.swift',root/'docs/qa/powerpoint-revision-automation-native-2026-10-20.swift',root/'docs/qa/presentation-result-native-2026-10-20.swift'],sources)
def verify_editable_outputs(directory, cases=None):
    """Independent stdlib ZIP/XML reader; no production parser is imported."""
    relation_ns = 'http://schemas.openxmlformats.org/package/2006/relationships'
    drawing_ns = 'http://schemas.openxmlformats.org/drawingml/2006/main'
    content_ns = 'http://schemas.openxmlformats.org/package/2006/content-types'
    presentation_ns = 'http://schemas.openxmlformats.org/presentationml/2006/main'
    for name, expected in cases or [('reviewed.pptx', ['New first', 'New second']), ('macros.pptm', ['Macro first', 'Macro second'])]:
        path=directory/name
        with zipfile.ZipFile(path) as archive:
            assert archive.testzip() is None, 'Independent CRC failure: '+name
            assert len(archive.namelist()) == len(set(archive.namelist())), 'Duplicate output parts'
            parts={item:archive.read(item) for item in archive.namelist()}
        parsed={part:ET.fromstring(data) for part,data in parts.items() if part.endswith(('.xml','.rels'))}
        for part, xml in parsed.items():
            if not part.endswith('.rels'): continue
            assert xml.tag=='{'+relation_ns+'}Relationships', part
            owner='' if part=='_rels/.rels' else part.replace('/_rels/','/').removesuffix('.rels')
            ids=set()
            for edge in xml:
                assert edge.attrib['Id'] not in ids, 'Duplicate relationship ID'
                ids.add(edge.attrib['Id'])
                if edge.attrib.get('TargetMode')=='External':continue
                target=unquote(edge.attrib['Target'])
                resolved=posixpath.normpath(target.lstrip('/') if target.startswith('/') else posixpath.join(posixpath.dirname(owner),target))
                assert resolved in parts, (part,resolved)
        root=parsed['ppt/presentation.xml']
        assert root.find('{'+presentation_ns+'}sldMasterIdLst') is not None, 'Missing slide masters'
        assert any('/slideLayouts/' in part for part in parts), 'Missing slide layout graph'
        assert any('/theme/' in part for part in parts), 'Missing theme graph'
        text=[node.text for part,xml in parsed.items() if part.startswith('ppt/slides/') and part.endswith('.xml') for node in xml.iter('{'+drawing_ns+'}t')]
        assert text==expected, (name,text)
        main=next(node.attrib['ContentType'] for node in parsed['[Content_Types].xml'] if node.tag=='{'+content_ns+'}Override' and node.attrib.get('PartName')=='/ppt/presentation.xml')
        assert ('macroEnabled' in main)==name.endswith('.pptm'), (name,main)
        if name.endswith('.pptm'):assert parts['ppt/vbaProject.bin']==bytes([0,1,2,3])
        print('PASS: independent ZIP CRC/XML relationship graph, selected text and format: '+name,flush=True)

with tempfile.TemporaryDirectory(prefix='turtlegit-presentation-review-') as temporary:
    for case in args.only or ['automation','review','routing','lifecycle','revision','revision-automation','result']:
        for index,git in enumerate((args.git or [Path('/usr/bin/git')]) if case=='result' else [(args.git or [Path('/usr/bin/git')])[0]]):
            directory=Path(temporary)/(case+str(index));directory.mkdir()
            env={key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
            config=directory/'global.config';config.write_text('')
            home=directory/'home';home.mkdir(mode=0o700)
            env.update(GIT_CONFIG_GLOBAL=str(config),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',CFFIXED_USER_HOME=str(home),XDG_CONFIG_HOME=str(directory/'xdg'),DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),TURTLEGIT_PRESENTATION_CASE=case)
            private_tmp=directory/'temporary';private_tmp.mkdir(mode=0o700);env['TMPDIR']=str(private_tmp)
            if args.captures and case=='review':env['TURTLEGIT_PRESENTATION_CAPTURES']=str(args.captures.absolute())
            if args.captures and case=='revision' and index==0:env['TURTLEGIT_PRESENTATION_REVISION_CAPTURE_DIR']=str(args.captures.absolute())
            if args.captures and case=='result' and index==0:env['TURTLEGIT_PRESENTATION_RESULT_CAPTURE_DIR']=str(args.captures.absolute())
            if case=='result':
                result_output=(args.output_dir.absolute()/('result'+str(index))) if args.output_dir else directory/'result-output'
                env['TURTLEGIT_PRESENTATION_RESULT_OUTPUT_DIR']=str(result_output)
            if case=='revision':
                output=(args.output_dir.absolute()/str(index)) if args.output_dir else directory/'output'
                env['TURTLEGIT_PRESENTATION_REVISION_OUTPUT_DIR']=str(output)
            print('Checking presentation '+case,flush=True)
            result=run_receiver([str(receiver),str(directory),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True,timeout_sample=directory/'timeout.sample.txt')
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: presentation native review completed' not in result.stdout:raise SystemExit('Presentation receiver exited before completion: '+case)
            if case=='revision':verify_editable_outputs(output)
            if case=='result':verify_editable_outputs(result_output, [('mixed.pptx', ['New first', 'Base second', 'Second slide first', 'Second slide second'])])
