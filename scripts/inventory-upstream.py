#!/usr/bin/env python3
"""Pin and inventory every upstream file; preserve review decisions across regeneration."""
import csv
import json
import io
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
UPSTREAM = ROOT / '.upstream/TortoiseGit'
DEST = ROOT / 'docs/upstream-files.csv'

def git(*args):
    return subprocess.check_output(['git', '-C', str(UPSTREAM), *args])

def write_csv(path, fields, rows):
    # Validate and serialize before replacing an existing audit file.
    buffer = io.StringIO(newline='')
    writer = csv.DictWriter(buffer, fieldnames=fields, lineterminator='\n')
    writer.writeheader(); writer.writerows(rows)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(buffer.getvalue())
    temporary.replace(path)

def main():
    if not UPSTREAM.exists():
        raise SystemExit('Clone upstream into .upstream/TortoiseGit first; see README.md.')
    commit = git('rev-parse', 'HEAD').decode().strip()
    previous = {}
    if DEST.exists():
        with DEST.open(newline='') as stream:
            previous = {r['path']: r for r in csv.DictReader(stream)}
    rows = []
    for record in git('ls-tree', '-r', '-z', 'HEAD').split(b'\0'):
        if not record:
            continue
        metadata, path = record.split(b'\t', 1)
        mode, kind, blob = metadata.decode().split()
        path = path.decode()
        prior = previous.get(path, {})
        component = path.split('/')[1] if path.startswith('src/') else path.split('/')[0]
        status = prior.get('status', 'pending-review')
        if prior.get('blob') and prior['blob'] != blob:
            status = 'upstream-changed-needs-review'
        rows.append(dict(path=path, component=component, kind=kind, blob=blob,
                         status=status, mac_replacement=prior.get('mac_replacement', ''),
                         notes=prior.get('notes', '')))
    DEST.parent.mkdir(exist_ok=True)
    write_csv(DEST, ['path', 'component', 'kind', 'blob', 'status', 'mac_replacement', 'notes'], rows)
    previous_dialogs = {}
    dialog_path = ROOT / "docs/upstream-dialogs.csv"
    if dialog_path.exists():
        with dialog_path.open(newline="") as stream:
            previous_dialogs = {(r["resource"], r["id"]): r for r in csv.DictReader(stream)}
    dialogs = []
    for row in rows:
        if not row['path'].endswith('.rc'):
            continue
        data = (UPSTREAM / row['path']).read_bytes()
        text = data.decode('utf-16' if data[:2] in (b'\xff\xfe', b'\xfe\xff') else 'utf-8', errors='replace')
        for match in re.finditer(r'^\s*(\w+)\s+DIALOG(?:EX)?\b[^\n]*', text, re.M):
            next_start = text.find('\nEND', match.end())
            block = text[match.end():next_start] if next_start >= 0 else ''
            caption = re.search(r'^\s*CAPTION\s+"([^"]*)"', block, re.M)
            dialogs.append({'resource': row['path'], 'id': match.group(1),
                            'caption': caption.group(1) if caption else '',
                            'status': previous_dialogs.get((row['path'], match.group(1)), {}).get('status', 'pending-review')})
    write_csv(ROOT / 'docs/upstream-dialogs.csv', ['resource', 'id', 'caption', 'status'], dialogs)
    manifest = {'repository': 'https://github.com/TortoiseGit/TortoiseGit', 'commit': commit,
                'tracked_entries': len(rows), 'dialog_resources': len(dialogs),
                'note': 'Inventory coverage is not implementation coverage. Every file and dialog requires review.'}
    (ROOT / 'docs/upstream.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest, indent=2))

if __name__ == '__main__':
    main()
