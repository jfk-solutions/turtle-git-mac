#!/usr/bin/env python3
"""Collect bounded, redacted diagnostics from finalized nonzero Actions steps.

Only UUID status/stream records in --logs are read. Scripts, environments, native
repositories and private fixture trees are never traversed. Unfinished records
are explicitly incomplete, not successful; only the inherited active collector
UUID is excluded. EXIT-trap replacement and abrupt runner termination can leave
such incomplete records without an attributable numeric exit status.
"""
import argparse
import collections
import errno
import json
import os
from pathlib import Path
import re
import stat
import sys

MAX_FILE_BYTES = 64 * 1024
MAX_TOTAL_BYTES = 2 * 1024 * 1024
SUMMARY_RESERVE = 256 * 1024
MAX_SCAN_BYTES = 64 * 1024 * 1024
MAX_LINE_BYTES = 64 * 1024
MAX_DETAILS = 256
UUID = r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
RECORD = re.compile(r'^(' + UUID + r')\.(status|stdout\.log|stderr\.log)$')
ACTIVE = re.compile(r'^' + UUID + r'$')
TOKEN = re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{16,})\b')
AUTH = re.compile(r'''(?i)(\bauthorization["']?\s*[:=]\s*)[^\r\n]*''')
ASSIGNMENT = re.compile(r'''(?ix)
    (\b(?:[a-z0-9]+[_-])*
      (?:password|passwd|pwd|secret|token|pat|client[_-]?secret|private[_-]?key|
         credential|signature|sig|api[_-]?key|access[_-]?key|awsaccesskeyid|key)
      (?:[_-][a-z0-9]+)*["']?\s*[:=]\s*)
    (?:"(?:\\.|[^"\\\r\n])*"|'(?:\\.|[^'\\\r\n])*'|(?P<open_value>"[^\r\n]*|'[^\r\n]*)|(?:\\.|[^\s,;])+)
''')
URL_AUTH = re.compile(r'(?i)(\b[a-z][a-z0-9+.-]*://)[^\s/@:]+:[^\s/@]+@')
PEM_BEGIN = re.compile(r'-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----')
PEM_END = re.compile(r'-----END (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----')
# Native fixtures report named failures without XCTest/Swift fatal headers.
# Recognize the emitted `... failed:` envelope and exact reference-group result,
# not incidental words in passing cancellation/failure-recovery assertions.
MARKER = re.compile(
    r'(?i)fatal error|errorraisedattoplevel|xctassert|traceback \(most recent call last\)|'
    r'^(?:[^\r\n]*:\d+(?::\d+)?:\s*)?error:\s|'
    r'assertion(?:error| failed| failure)|failed assertion|uncaught exception|precondition failed|'
    r'^[A-Za-z][A-Za-z0-9 /_.()\x27-]{0,119} failed:[ \t]*\S|'
    r'^Failed reference group [1-9][0-9]*; engine=[^\r\n]+; exit=[^;\r\n]+; cases=\S')


def clip(text, limit):
    return text.encode('utf-8')[:max(0, limit)].decode('utf-8', 'ignore')


def directory_fd(path, create=False):
    """Open every component without following a directory symlink."""
    absolute = Path(os.path.abspath(path))
    descriptor = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in absolute.parts[1:]:
            if create:
                try:
                    os.mkdir(component, 0o700, dir_fd=descriptor)
                except FileExistsError:
                    pass
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def regular_fd(directory, name):
    descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    metadata = os.fstat(descriptor)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        os.close(descriptor)
        raise ValueError('not a private regular file')
    return descriptor, metadata


class Redactor:
    def __init__(self):
        self.in_private_key = False
        self.secret_quote = None
        self.counts = collections.Counter()

    def line(self, text):
        if self.secret_quote is not None:
            # An unterminated quoted assignment may continue on later lines.
            # Omit through its closing line instead of exposing the remainder.
            if re.search(r'(?<!\\)' + re.escape(self.secret_quote), text):
                self.secret_quote = None
            return ''
        # Scan from the beginning, even when retaining only bounded selections;
        # a tail beginning in the middle of a key must never leak key material.
        if self.in_private_key:
            if PEM_END.search(text):
                self.in_private_key = False
            return ''
        if PEM_BEGIN.search(text):
            self.counts['private_key_blocks'] += 1
            self.in_private_key = PEM_END.search(text) is None
            return '[REDACTED PRIVATE KEY BLOCK]\n'
        text, count = URL_AUTH.subn(r'\1[REDACTED]@', text)
        self.counts['url_credentials'] += count
        text, count = AUTH.subn(r'\1[REDACTED]', text)
        self.counts['authorization'] += count
        def assigned(match):
            opened = match.group('open_value')
            if opened:
                self.secret_quote = opened[0]
                self.counts['unterminated_quoted_assignments'] += 1
            return match.group(1) + '[REDACTED]'
        text, count = ASSIGNMENT.subn(assigned, text)
        self.counts['assignments'] += count
        text, count = TOKEN.subn('[REDACTED GITHUB TOKEN]', text)
        self.counts['github_tokens'] += count
        return text


def stream_selection(descriptor, metadata):
    redactor = Redactor()
    head = ''
    tail = ''
    context = ''
    recent = collections.deque(maxlen=4)
    recent_after = 0
    previous = ''
    after = 0
    contexts = 0
    markers = 0
    scanned = 0
    replacements = 0
    stopped = None
    with os.fdopen(descriptor, 'rb') as source:
        while True:
            raw = source.readline(MAX_LINE_BYTES + 1)
            if not raw:
                break
            scanned += len(raw)
            if len(raw) > MAX_LINE_BYTES:
                # Never emit a chopped secret/token or resume after a lost PEM
                # header. An oversized line omits the rest of this source file.
                stopped = 'overlong line; remainder omitted for safe redaction'
                break
            if scanned > MAX_SCAN_BYTES:
                stopped = 'scan byte limit; remainder omitted'
                break
            text = raw.decode('utf-8', 'replace')
            replacements += text.count('\ufffd')
            for line in text.replace('\r\n', '\n').replace('\r', '\n').splitlines(keepends=True):
                line = redactor.line(line)
                if not line:
                    continue
                head = clip(head + line, 4 * 1024)
                tail = (tail + line).encode('utf-8')[-10 * 1024:].decode('utf-8', 'ignore')
                if MARKER.search(line):
                    markers += 1
                    recent.append(clip(previous + line, 2048))
                    recent_after = max(0, 2048 - len(recent[-1].encode('utf-8')))
                    if contexts < 4 and len(context.encode('utf-8')) < 8 * 1024:
                        context = clip(context + '\n--- diagnostic context ---\n' + previous + line, 8 * 1024)
                        contexts += 1
                        after = 2048
                elif after:
                    addition = clip(line, after)
                    context = clip(context + addition, 8 * 1024)
                    after -= len(addition.encode('utf-8'))
                if recent and recent_after and not MARKER.search(line):
                    addition = clip(line, recent_after)
                    recent[-1] += addition
                    recent_after -= len(addition.encode('utf-8'))
                previous = (previous + line).encode('utf-8')[-1024:].decode('utf-8', 'ignore')
    latest = ''.join('\n--- latest diagnostic context ---\n' + text for text in recent)
    sections = [('diagnostic contexts', context), ('latest diagnostic contexts', latest), ('head', head), ('tail', tail)]
    result = ''.join('\n--- ' + label + ' ---\n' + text for label, text in sections if text)
    return result, dict(input_bytes=metadata.st_size, scanned_bytes=scanned,
                        scan_complete=stopped is None, omitted_reason=stopped,
                        selection_truncated=metadata.st_size > len(result.encode('utf-8')),
                        diagnostic_markers=markers, retained_early_contexts=contexts, retained_latest_contexts=len(recent),
                        utf8_replacements=replacements, private_key_open_at_end=redactor.in_private_key, quoted_secret_open_at_end=redactor.secret_quote is not None,
                        redactions=dict(redactor.counts))


def read_status(directory, name):
    descriptor, metadata = regular_fd(directory, name)
    with os.fdopen(descriptor, 'rb') as source:
        value = source.read(65)
    if metadata.st_size > 64 or not re.fullmatch(rb'[0-9]{1,3}\n?', value):
        raise ValueError('malformed numeric status')
    result = int(value)
    if result > 255:
        raise ValueError('status outside shell range')
    return result


def write_file(directory, name, contents):
    descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory)
    with os.fdopen(descriptor, 'wb') as destination:
        destination.write(contents)


def output_flags(present, incomplete):
    target = os.environ.get('GITHUB_OUTPUT')
    if not target:
        return
    parent = directory_fd(Path(target).parent)
    try:
        descriptor = os.open(Path(target).name, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    finally:
        os.close(parent)
    metadata = os.fstat(descriptor)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        os.close(descriptor)
        raise ValueError('GITHUB_OUTPUT is not a private regular file')
    with os.fdopen(descriptor, 'a') as destination:
        destination.write('present=' + str(present).lower() + '\nincomplete=' + str(incomplete).lower() + '\n')


def collect(logs, output, checkpoint, active=None):
    source = destination = None
    summary = dict(schema=1, checkpoint=checkpoint, assessment='recorded statuses only; not a job-success verdict',
                   limits=dict(per_report_bytes=MAX_FILE_BYTES, total_output_bytes=MAX_TOTAL_BYTES,
                               source_scan_bytes=MAX_SCAN_BYTES, source_line_bytes=MAX_LINE_BYTES),
                   failed_steps=0, successful_statuses=0, incomplete_steps=0, incomplete_streams=0, excluded_active_step=None,
                   ignored_entries=0, detail_entries_omitted=0, reports_omitted=0, steps=[], collection_errors=[])
    budget = MAX_TOTAL_BYTES - SUMMARY_RESERVE
    total = 0
    try:
        destination = directory_fd(output, create=True)
        if os.listdir(destination):
            raise ValueError('output directory must be empty')
        try:
            source = directory_fd(logs)
        except OSError as failure:
            summary['collection_errors'].append('log directory unavailable (errno ' + str(failure.errno) + ')')
        records = {}
        if source is not None:
            for name in os.listdir(source):
                match = RECORD.fullmatch(name)
                if not match:
                    summary['ignored_entries'] += 1
                    continue
                identity, kind = match.groups()
                records.setdefault(identity, set()).add(kind)
        if active and ACTIVE.fullmatch(active) and active in records:
            summary['excluded_active_step'] = active
            del records[active]
        for identity in sorted(records):
            item = dict(uuid=identity)
            try:
                if 'status' not in records[identity]:
                    raise ValueError('missing final status')
                code = read_status(source, identity + '.status')
            except (OSError, ValueError) as failure:
                summary['incomplete_steps'] += 1
                item['state'] = 'incomplete'
                item['reason'] = 'missing, malformed or unsafe status' if isinstance(failure, OSError) else str(failure)
                if len(summary['steps']) < MAX_DETAILS:
                    summary['steps'].append(item)
                else:
                    summary['detail_entries_omitted'] += 1
                continue
            if code == 0:
                summary['successful_statuses'] += 1
                continue
            summary['failed_steps'] += 1
            item.update(state='failed', exit_code=code, streams={})
            report = 'Actions step ' + identity + '\nExit status: ' + str(code) + '\n'
            for stream in ('stdout', 'stderr'):
                name = identity + '.' + stream + '.log'
                try:
                    descriptor, metadata = regular_fd(source, name)
                    selected, details = stream_selection(descriptor, metadata)
                    item['streams'][stream] = details
                    if not details['scan_complete']:
                        summary['incomplete_streams'] += 1
                    report += '\n=== ' + stream + ' ===\n' + selected
                except (OSError, ValueError):
                    summary['incomplete_streams'] += 1
                    item['streams'][stream] = dict(omitted_reason='missing or unsafe regular stream file')
                    report += '\n=== ' + stream + ' ===\n[stream missing or unsafe; omitted]\n'
            raw = report.encode('utf-8')
            available = min(MAX_FILE_BYTES, max(0, budget - total))
            if available:
                if len(raw) > available:
                    suffix = b'\n[report truncated by output byte limit]\n'
                    raw = clip(report, max(0, available - len(suffix))).encode('utf-8') + suffix[:available]
                    raw = raw[:available]
                    item['report_truncated'] = True
                name = identity + '.txt'
                write_file(destination, name, raw)
                item['report'] = name
                item['report_bytes'] = len(raw)
                total += len(raw)
            else:
                item['report_omitted'] = 'total output byte limit'
                summary['reports_omitted'] += 1
            if len(summary['steps']) < MAX_DETAILS:
                summary['steps'].append(item)
            else:
                summary['detail_entries_omitted'] += 1
        summary['failed'] = summary['failed_steps'] > 0
        summary['incomplete'] = bool(summary['incomplete_steps'] or summary['incomplete_streams'] or summary['collection_errors'])
        summary['present'] = summary['failed'] or summary['incomplete']
        summary['report_bytes'] = total
        while True:
            encoded = (json.dumps(summary, indent=2, sort_keys=True) + '\n').encode('utf-8')
            if len(encoded) <= SUMMARY_RESERVE:
                break
            summary['steps'].pop()
            summary['detail_entries_omitted'] += 1
        write_file(destination, 'summary.json', encoded)
        output_flags(summary['present'], summary['incomplete'])
        return summary
    finally:
        if source is not None:
            os.close(source)
        if destination is not None:
            os.close(destination)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--logs', type=Path, default=Path('build/ci-step-logs'))
    parser.add_argument('--checkpoint', required=True)
    parser.add_argument('--output', type=Path, required=True)
    arguments = parser.parse_args(argv)
    if not re.fullmatch(r'[A-Za-z0-9_.-]{1,80}', arguments.checkpoint):
        parser.error('checkpoint must be a short identifier')
    logs, output = os.path.abspath(arguments.logs), os.path.abspath(arguments.output)
    if os.path.commonpath([logs, output]) in (logs, output):
        parser.error('logs and output must be separate directory trees')
    result = collect(logs, output, arguments.checkpoint, os.environ.get('TURTLEGIT_CI_STEP_LOG_ACTIVE'))
    print('CI step diagnostics: failed=' + str(result['failed_steps']) + ', incomplete=' + str(result['incomplete_steps']) + ', reports omitted=' + str(result['reports_omitted']))
    return 0


if __name__ == '__main__':
    sys.exit(main())
