#!/usr/bin/env python3
"""Verify copied help resources and create Apple's local search/anchor index."""
from pathlib import Path
import argparse
import hashlib
from html.parser import HTMLParser
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import time
from urllib.parse import unquote, urlsplit

HELP_INDEX_TIMEOUT = 300
HELP_INDEX_NAME = 'TurtleGitHelp.cshelpindex'
LEGACY_INDEX_NAME = 'TurtleGitHelp.helpindex'
HELP_INDEX_FORMAT = 'corespotlight'


def validated_book(app, *, allow_legacy=False):
    app = Path(app)
    book = app / 'Contents/Resources/TurtleGitHelp.help'
    manifest = json.loads((book / 'Contents/Resources/manifest.json').read_text())
    for name, digest in manifest['files'].items():
        path = book / name
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise SystemExit('Missing/stale help resource: ' + name)
    info = plistlib.loads((book / 'Contents/Info.plist').read_bytes())
    if info.get('HPDBookCSIndexPath') != HELP_INDEX_NAME or 'HPDBookIndexPath' in info:
        raise SystemExit('Help book must declare its modern HPDBookCSIndexPath without a legacy LSM index.')
    locale = book / 'Contents/Resources/en.lproj'
    index = locale / HELP_INDEX_NAME
    expected = set(manifest['files']) | {'Contents/Resources/manifest.json', str(index.relative_to(book))}
    if allow_legacy:
        expected.add(str((locale / LEGACY_INDEX_NAME).relative_to(book)))
    actual = {str(path.relative_to(book)) for path in book.rglob('*') if path.is_file() or path.is_symlink()}
    if actual - expected:
        raise SystemExit('Unexpected bundled Help files: ' + ', '.join(sorted(actual - expected)))
    html = {str(Path(name).relative_to('Contents/Resources/en.lproj')) for name in manifest['files']
            if name.startswith('Contents/Resources/en.lproj/') and name.endswith('.html')}
    catalog = json.loads((locale / 'topics.json').read_text())
    anchors = {'topic-home': ('index.html', 'topic-home')}
    for topic in catalog['topics']:
        identity, document = topic['id'], topic['document']
        if not isinstance(identity, str) or not identity or not isinstance(document, str) or '/' in document or not document.endswith('.md'):
            raise SystemExit('Invalid bundled Help topic identity/document.')
        anchor = 'topic-' + identity
        if anchor in anchors:
            raise SystemExit('Duplicate bundled Help anchor: ' + anchor)
        anchors[anchor] = (str(Path(document).with_suffix('.html')), anchor)
    return locale, index, html, anchors


def inspected_index(index, locale, html, anchors, *, execute, deadline, timeout):
    if index.is_symlink() or not index.is_file() or index.stat().st_size == 0:
        raise RuntimeError('Apple Help index was not generated.')

    def inspect(flag):
        argv = ['/usr/bin/hiutil', '-I', HELP_INDEX_FORMAT, flag, '-f', str(index)]
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise subprocess.TimeoutExpired(argv, timeout)
        return execute(argv, check=True, timeout=remaining, capture_output=True).stdout

    def target(value):
        parts = urlsplit(value)
        if parts.scheme or parts.netloc:
            raise RuntimeError('Apple Help index contains a nonlocal document URL.')
        return unquote(parts.path).lstrip('/'), unquote(parts.fragment)

    dictionary = plistlib.loads(inspect('-D'))
    if not isinstance(dictionary, dict):
        raise RuntimeError('Apple Help anchor index is not a dictionary.')

    class NamedAnchors(HTMLParser):
        def __init__(self):
            super().__init__()
            self.names = set()

        def handle_starttag(self, tag, attributes):
            if tag == 'a':
                self.names.update(value for key, value in attributes if key == 'name' and value is not None)

    named = {}
    for document in {expected[0] for expected in anchors.values()}:
        parsed = NamedAnchors()
        parsed.feed((locale / document).read_text(encoding='utf-8'))
        named[document] = parsed.names
    for anchor, expected in anchors.items():
        values = dictionary.get(anchor)
        if not isinstance(values, list) or not values or not all(isinstance(value, str) for value in values):
            raise RuntimeError('Apple Help index is missing the document target for ' + anchor)
        resolved = [target(value) for value in values]
        # hiutil -D maps exact anchor keys to files containing them. Multiple
        # aliases can share that file's canonical first-anchor URL, rather than
        # each alias's own fragment. Preserve exact key and chapter identity;
        # verify both the requested named anchor and reported canonical anchor
        # against the actual hash-validated chapter, without case folding.
        if any(document != expected[0] for document, _ in resolved):
            raise RuntimeError('Apple Help index has the wrong document target for ' + anchor)
        if expected[1] not in named[expected[0]]:
            raise RuntimeError('Bundled Help chapter is missing the named anchor for ' + anchor)
        if any(not fragment or fragment not in named[document] for document, fragment in resolved):
            raise RuntimeError('Apple Help index has an unknown canonical anchor for ' + anchor)
    files = {target(line)[0] for line in inspect('-F').decode('utf-8').splitlines() if line.strip()}
    if files != html:
        raise RuntimeError('Apple Help indexed HTML inventory differs from the bundled guides.')


def report_failure(began, error):
    if isinstance(error, subprocess.CalledProcessError) and error.stderr:
        diagnostic = error.stderr.decode('utf-8', errors='replace') if isinstance(error.stderr, bytes) else error.stderr
        print(diagnostic, file=sys.stderr, flush=True)
    print('Bundled Mac help indexing failed after ' + format(time.monotonic() - began, '.2f') + 's.',
          file=sys.stderr, flush=True)


def index_help(app, *, runner=None, timeout=HELP_INDEX_TIMEOUT):
    """Publish one successfully generated CoreSpotlight index atomically.

    Callable/deadline injection serves the focused contracts; the build entry
    always uses Apple's fixed tool. Generation and two read-only inspections
    share one deadline. subprocess.run kills/waits its exact timed-out child.
    No metadata daemon is signalled and no generation is retried.
    """
    locale, index, html, anchors = validated_book(app, allow_legacy=True)
    execute = subprocess.run if runner is None else runner
    began = time.monotonic()
    deadline = began + timeout
    print('Indexing bundled Mac help (one attempt; deadline ' + str(timeout) + 's):', locale, flush=True)
    try:
        # Sibling staging is outside hiutil's input tree and on the publication
        # volume. A failed tool can leave only private, disposable partial data.
        with tempfile.TemporaryDirectory(prefix='.turtlegit-help-index-', dir=locale.parent) as temporary:
            staging = Path(temporary)
            if staging.stat().st_dev != locale.stat().st_dev:
                raise RuntimeError('Apple Help index staging is not on the publication volume.')
            prepared = staging / index.name
            execute(['/usr/bin/hiutil', '-I', HELP_INDEX_FORMAT, '-C', '-a', '-s', 'en', '-f', str(prepared), str(locale)],
                    check=True, timeout=max(0, deadline - time.monotonic()))
            inspected_index(prepared, locale, html, anchors, execute=execute, deadline=deadline, timeout=timeout)
            size = prepared.stat().st_size
            # Incremental resource copies can retain the old build-owned LSM
            # filename. Retire only that file after the new index is complete;
            # a failed tool/inspection leaves both prior files untouched.
            (locale / LEGACY_INDEX_NAME).unlink(missing_ok=True)
            os.replace(prepared, index)
    except Exception as error:
        report_failure(began, error)
        raise
    print('Indexed bundled Mac help:', size, 'bytes in', format(time.monotonic() - began, '.2f') + 's', flush=True)
    return index


def verify_help_index(app, *, runner=None, timeout=HELP_INDEX_TIMEOUT):
    locale, index, html, anchors = validated_book(app)
    execute = subprocess.run if runner is None else runner
    began = time.monotonic()
    try:
        inspected_index(index, locale, html, anchors, execute=execute, deadline=began + timeout, timeout=timeout)
    except Exception as error:
        report_failure(began, error)
        raise
    print('Verified CoreSpotlight Help index:', len(html), 'HTML files and', len(anchors), 'named topic anchors;', locale, flush=True)
    return index


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify', action='store_true', help='Inspect an existing current-build index without generating or changing it.')
    parser.add_argument('app', type=Path)
    arguments = parser.parse_args()
    (verify_help_index if arguments.verify else index_help)(arguments.app)
