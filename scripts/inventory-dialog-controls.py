#!/usr/bin/env python3
"""Inventory static controls at the pinned upstream commit, without claiming parity."""
import csv
import io
import json
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
UPSTREAM = ROOT / '.upstream/TortoiseGit'
TARGET = ROOT / 'docs/upstream-controls.csv'
KINDS = {'CONTROL', 'LTEXT', 'RTEXT', 'CTEXT', 'GROUPBOX', 'PUSHBUTTON',
         'DEFPUSHBUTTON', 'EDITTEXT', 'COMBOBOX', 'LISTBOX', 'ICON', 'SCROLLBAR',
         'CHECKBOX', 'AUTOCHECKBOX', 'RADIOBUTTON', 'AUTORADIOBUTTON'}

def main():
    manifest = json.loads((ROOT / 'docs/upstream.json').read_text())
    with (ROOT / 'docs/upstream-dialogs.csv').open(newline='') as stream:
        dialogs = list(csv.DictReader(stream))
    previous = {}
    if TARGET.exists():
        with TARGET.open(newline='') as stream:
            previous = {(r['resource'], r['dialog'], r['control'], r['occurrence']): r for r in csv.DictReader(stream)}
    rows, found = [], set()
    for resource in sorted({r['resource'] for r in dialogs}):
        data = subprocess.check_output(['git', '-C', str(UPSTREAM), 'show', manifest['commit'] + ':' + resource])
        text = data.decode('utf-16' if data[:2] in (b'\xff\xfe', b'\xfe\xff') else 'utf-8')
        wanted = {r['id'] for r in dialogs if r['resource'] == resource}
        for match in re.finditer(r'^\s*(\w+)\s+DIALOG(?:EX)?\b[^\n]*', text, re.M):
            dialog = match.group(1)
            if dialog not in wanted:
                continue
            found.add((resource, dialog))
            end = re.search(r'^END\s*$', text[match.end():], re.M)
            if not end:
                raise ValueError('Missing dialog END: ' + dialog)
            block = text[match.end():match.end() + end.start()]
            controls = []
            for line in block.splitlines():
                stripped = line.strip()
                kind = stripped.split(maxsplit=1)[0] if stripped else ''
                if kind in KINDS:
                    controls.append(stripped)
                elif controls and stripped and kind not in {'STYLE', 'EXSTYLE', 'CAPTION', 'FONT', 'BEGIN'}:
                    controls[-1] += ' ' + stripped
            occurrences = {}
            for declaration in controls:
                kind, values = declaration.split(maxsplit=1)
                fields = re.findall(r'"(?:[^"]|"")*"|[^,]+', values)
                fields = [v.strip() for v in fields]
                labelled = kind not in {'EDITTEXT', 'COMBOBOX', 'LISTBOX', 'SCROLLBAR'}
                control = fields[1] if labelled else fields[0]
                label = fields[0].strip('"') if labelled else ''
                occurrences[control] = occurrences.get(control, 0) + 1
                occurrence = str(occurrences[control])
                prior = previous.get((resource, dialog, control, occurrence), {})
                rows.append(dict(resource=resource, dialog=dialog, control=control,
                                 occurrence=occurrence, kind=kind, label=label,
                                 declaration=declaration, status=prior.get('status', 'pending-review'),
                                 native_mapping=prior.get('native_mapping', ''), notes=prior.get('notes', '')))
    expected = {(r['resource'], r['id']) for r in dialogs}
    if found != expected:
        raise ValueError('Dialog coverage mismatch: ' + str(expected - found))
    buffer = io.StringIO(newline='')
    writer = csv.DictWriter(buffer, fieldnames=['resource', 'dialog', 'control', 'occurrence', 'kind', 'label', 'declaration', 'status', 'native_mapping', 'notes'], lineterminator='\n')
    writer.writeheader(); writer.writerows(rows)
    temporary = TARGET.with_suffix('.csv.tmp')
    temporary.write_text(buffer.getvalue()); temporary.replace(TARGET)
    print(f'{len(found)} dialogs, {len(rows)} static controls; dynamic controls still require source review.')

if __name__ == '__main__':
    main()
