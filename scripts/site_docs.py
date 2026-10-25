"""Render repository documentation as static, searchable Pages documents."""
from html import escape
import json
import re
from urllib.parse import quote, unquote, urlsplit
from markdown_it import MarkdownIt


def slug(text):
    return re.sub(r'[^\w\- ]', '', text.lower(), flags=re.UNICODE).replace(' ', '-')


def page_shell(title, body, repository, toc=''):
    return f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{escape(title)} — TurtleGit for Mac</title><link rel="icon" type="image/png" href="../assets/application-favicon.png"><link rel="stylesheet" href="../style.css"><link rel="stylesheet" href="manual.css"></head>
<body><a class="skip-link" href="#content">Skip to content</a>
<header><a class="brand" href="../index.html"><img src="../assets/application-icon.png" width="36" height="36" alt="">TurtleGit for Mac</a><nav aria-label="Main"><a href="index.html">Documentation</a><a href="GETTING-STARTED.html">Getting started</a><a href="https://github.com/{repository}">Source ↗</a></nav></header>
<main class="manual-layout"><aside class="manual-sidebar" aria-label="On this page">{toc}</aside><article id="content" class="manual-content">{body}</article></main>
<footer><p>TurtleGit for Mac · A macOS fork of TortoiseGit · macOS port by Jochen Kühner.</p><p><a href="https://github.com/{repository}/blob/main/LICENSE">License</a> · <a href="https://github.com/{repository}/blob/main/NOTICE">Attribution</a></p></footer></body></html>'''


def render_documents(root, destination, repository):
    root = root.resolve()
    docs = root / 'docs'
    output = destination / 'manual'
    output.mkdir(parents=True, exist_ok=True)
    for old_page in output.glob('*.html'):
        old_page.unlink()
    catalog, local_links = [], []
    files = sorted(docs.glob('*.md'))
    page_names = {p.resolve(): p.stem + '.html' for p in files}
    for source in files:
        md = MarkdownIt('commonmark', {'html': False}).enable(['table', 'strikethrough'])
        tokens = md.parse(source.read_text())
        headings, ids, text_parts = [], {}, []
        title = source.stem.replace('-', ' ').title()
        for i, token in enumerate(tokens):
            if token.type == 'heading_open':
                text = tokens[i + 1].content
                anchor = slug(text)
                count = ids.get(anchor, 0)
                ids[anchor] = count + 1
                if count:
                    anchor += '-' + str(count)
                token.attrSet('id', anchor)
                if token.tag == 'h1' and not headings:
                    title = text
                headings.append((token.tag, text, anchor))
            if token.type in {'inline', 'fence', 'code_block'}:
                text_parts.append(token.content)
            for child in token.children or []:
                attribute = 'href' if child.type == 'link_open' else 'src' if child.type == 'image' else None
                if not attribute:
                    continue
                parts = urlsplit(child.attrGet(attribute))
                if parts.scheme or parts.netloc or not parts.path:
                    continue
                path = (source.parent / unquote(parts.path)).resolve()
                suffix = ('?' + parts.query if parts.query else '') + ('#' + parts.fragment if parts.fragment else '')
                if path in page_names:
                    child.attrSet(attribute, page_names[path] + suffix)
                    local_links.append((source.name, path, parts.fragment))
                elif path.is_relative_to(docs / 'site') and path.is_file():
                    child.attrSet(attribute, '../' + quote(path.relative_to(docs / 'site').as_posix()) + suffix)
                elif path.is_relative_to(root):
                    child.attrSet(attribute, f'https://github.com/{repository}/blob/main/' + quote(path.relative_to(root).as_posix()) + suffix)
        body = md.renderer.render(tokens, md.options, {})
        toc = '<a href="index.html">← All documentation</a><h2>On this page</h2><ul>' + ''.join(f'<li><a href="#{escape(anchor, quote=True)}">{escape(text)}</a></li>' for tag, text, anchor in headings if tag == 'h2') + '</ul>'
        body = f'<p class="manual-source"><a href="https://github.com/{repository}/blob/main/docs/{quote(source.name)}">View Markdown source ↗</a></p>' + body
        (output / page_names[source.resolve()]).write_text(page_shell(title, body, repository, toc))
        category = 'audit' if source.stem.endswith('PARITY') or source.stem == 'IMPLEMENTATION-NOTES' else 'guide'
        catalog.append({'title': title, 'url': page_names[source.resolve()], 'kind': category, 'text': '\n'.join(text_parts), 'anchors': [h[2] for h in headings]})
    lookup = {p.resolve(): item for p, item in zip(files, catalog)}
    unresolved = [{'source': source, 'target': path.name, 'fragment': fragment} for source, path, fragment in local_links if fragment and unquote(fragment) not in lookup[path]['anchors']]
    (output / 'link-audit.json').write_text(json.dumps(unresolved, indent=2) + '\n')
    for item in catalog:
        item.pop('anchors')
    (output / 'search-index.json').write_text(json.dumps(catalog, ensure_ascii=False) + '\n')
    rows = ''.join(f'<li data-kind="{item["kind"]}"><a href="{escape(item["url"], quote=True)}">{escape(item["title"])}</a><span class="doc-kind">{"Source audit" if item["kind"] == "audit" else "Guide / reference"}</span></li>' for item in catalog)
    body = f'''<h1>TurtleGit user manual</h1><p>Work with Git in native Mac windows and Finder. Learn how to open a repository, choose changes for a commit, explore history and resolve conflicts.</p>
<p><a href="GETTING-STARTED.html">Getting started →</a> · <a href="GETTING-STARTED.html#start-from-finder">Finder commands →</a> · <a href="GETTING-STARTED.html#commit-with-checked-files">Commit changes →</a> · <a href="MERGE-TOOL.html">Compare and merge →</a> · <a href="README.html">All guides and references →</a></p>
<form id="doc-search" role="search"><label for="search">Search documentation</label><input id="search" name="q" type="search" placeholder="Commit, Finder, staging…" autocomplete="off"><label for="kind">Document type</label><select id="kind"><option value="all">All documents</option><option value="guide">Guides and references</option><option value="audit">Source audits</option></select></form>
<p id="search-status" role="status">{len(catalog)} documents. Search loads locally in your browser.</p><ol id="search-results" class="doc-results" hidden></ol><ul id="document-list" class="doc-list">{rows}</ul><script src="search.js" defer></script>'''
    (output / 'index.html').write_text(page_shell('Documentation', body, repository, '<a href="../index.html">← Screenshots and project</a>'))
    return {'documents': len(catalog), 'unresolved_fragments': unresolved}
