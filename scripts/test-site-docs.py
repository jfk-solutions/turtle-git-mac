#!/usr/bin/env python3
"""Batch acceptance for rendered Markdown and generated local links."""
from html.parser import HTMLParser
import json
from pathlib import Path
import tempfile
import unittest
from urllib.parse import unquote, urlsplit
from site_docs import render_documents


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links, self.ids = [], set()
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if 'id' in attrs:
            self.ids.add(attrs['id'])
        for name in ('href', 'src'):
            if name in attrs:
                self.links.append(attrs[name])


class SiteDocsTests(unittest.TestCase):
    def test_markdown_routes_anchors_code_and_escaping(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            docs = root / 'docs'; docs.mkdir()
            (docs / 'site/assets').mkdir(parents=True)
            (docs / 'site/assets/a.png').write_bytes(b'fixture')
            (docs / 'A.md').write_text('# A & B\n\n## Repeat\n\n## Repeat\n\n[Next](B.md#target) ![image](site/assets/a.png) [QA](qa/a.json)\n\n<script>alert(1)</script>\n\n```swift\nlet a = "<unsafe>"\n```\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n')
            (docs / 'B.md').write_text('# B\n\n## Target\n\n[Back](A.md#repeat-1)')
            destination = root / 'out'; destination.mkdir()
            report = render_documents(root, destination, 'owner/renamed-repo')
            page = (destination / 'manual/A.html').read_text()
            self.assertEqual(report, {'documents': 2, 'unresolved_fragments': []})
            for value in ('id="repeat-1"', 'href="B.html#target"', 'src="../assets/a.png"', 'https://github.com/owner/renamed-repo/blob/main/docs/qa/a.json', '&lt;script&gt;', '&lt;unsafe&gt;', '<table>'):
                self.assertIn(value, page)
            self.assertNotIn('<script>alert', page)
            self.assertEqual(len(json.loads((destination / 'manual/search-index.json').read_text())), 2)

    def test_curated_manual_keeps_complete_index_and_no_script_collections(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); docs = root / 'docs'; docs.mkdir()
            manifest = {'topics': [{'id': 'overview', 'document': 'START.md'},
                                    {'id': 'same', 'document': 'START.md'}],
                        'additional_guides': ['EXTRA.md', 'APPENDIX-PARITY.md']}
            (docs / 'help-topics.json').write_text(json.dumps(manifest))
            for name in ['START', 'EXTRA', 'APPENDIX-PARITY', 'DISTRIBUTION', 'IMPLEMENTATION-NOTES']:
                (docs / (name + '.md')).write_text('# ' + name + ' <unsafe>')
            destination = root / 'out'; destination.mkdir()
            render_documents(root, destination, 'owner/repo')
            catalog = json.loads((destination / 'manual/search-index.json').read_text())
            kinds = {item['url']: item['kind'] for item in catalog}
            self.assertEqual(kinds, {'START.html': 'guide', 'EXTRA.html': 'guide',
                                    'APPENDIX-PARITY.html': 'audit', 'DISTRIBUTION.html': 'reference',
                                    'IMPLEMENTATION-NOTES.html': 'audit'})
            index = (destination / 'manual/index.html').read_text()
            self.assertIn('<option value="guide" selected>User guides</option>', index)
            self.assertIn('2 user guides.', index)
            default = index.split('<ul id="document-list" class="doc-list">')[1].split('</ul>')[0]
            self.assertEqual(default.count(' hidden>'), 3)
            self.assertEqual(default.count('data-kind="guide"><a'), 2)
            fallback = index.split('<noscript>')[1].split('</noscript>')[0]
            self.assertIn('<summary>References</summary>', fallback)
            self.assertIn('<summary>Source audits</summary>', fallback)
            for name in ['DISTRIBUTION', 'APPENDIX-PARITY', 'IMPLEMENTATION-NOTES']:
                self.assertIn('href="' + name + '.html"', fallback)
            self.assertNotIn('<unsafe>', index)

    def test_generated_site_routes_and_fragments(self):
        site = Path(__file__).resolve().parent.parent / 'build/site'
        pages = list(site.rglob('*.html'))
        self.assertGreater(len(pages), 175)
        parsed = {}
        for page in pages:
            parser = Links(); parser.feed(page.read_text()); parsed[page.resolve()] = parser
        failures = []
        for page, parser in parsed.items():
            for link in parser.links:
                parts = urlsplit(link)
                if parts.scheme or parts.netloc:
                    continue
                target = (page.parent / unquote(parts.path)).resolve() if parts.path else page
                if target.is_dir():
                    target /= 'index.html'
                if not target.is_file():
                    failures.append(f'{page.name}: missing {link}')
                elif parts.fragment and target in parsed and unquote(parts.fragment) not in parsed[target].ids:
                    failures.append(f'{page.name}: missing anchor {link}')
        self.assertEqual(failures, [])
        self.assertEqual(json.loads((site / 'manual/link-audit.json').read_text()), [])


if __name__ == '__main__':
    unittest.main()
