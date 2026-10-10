#!/usr/bin/env python3
"""Check pinned inventory regeneration against isolated dirty and advanced upstreams."""
import csv
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def rows(path):
    with path.open(newline='') as stream:
        return list(csv.DictReader(stream))


def save(path, values):
    with path.open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(values[0]), lineterminator='\n')
        writer.writeheader()
        writer.writerows(values)


def main():
    with tempfile.TemporaryDirectory(prefix='turtlegit-inventory-pin-') as temporary:
        root = Path(temporary)
        upstream = root / '.upstream/TortoiseGit'
        upstream.mkdir(parents=True)
        (root / 'docs').mkdir()
        (root / 'scripts').mkdir()
        for name in ['inventory-upstream.py', 'inventory-dialog-controls.py']:
            shutil.copyfile(ROOT / 'scripts' / name, root / 'scripts' / name)

        def git(*args):
            return subprocess.check_output(['git', '-C', str(upstream), *args], stderr=subprocess.PIPE).decode().strip()

        def inventory(name, *args):
            return subprocess.check_output([sys.executable, str(root / 'scripts' / name), *args], stderr=subprocess.PIPE).decode()

        git('init', '-b', 'main')
        git('config', 'user.name', 'Inventory QA')
        git('config', 'user.email', 'inventory@example.invalid')
        git('config', 'commit.gpgsign', 'false')
        git('config', 'core.hooksPath', '/dev/null')
        resource = upstream / 'src/Fixture.rc'
        resource.parent.mkdir()
        old = '''IDD_FIXTURE DIALOGEX 0, 0, 100, 100
CAPTION "Pinned caption"
BEGIN
    PUSHBUTTON "Old action",IDOK,1,1,30,10
    PUSHBUTTON "Cancel",IDCANCEL,1,12,30,10
END
'''
        resource.write_text(old)
        git('add', '.'); git('commit', '-m', 'pinned')
        pinned = git('rev-parse', 'HEAD')
        (root / 'docs/upstream.json').write_text(json.dumps({'commit': pinned}))
        inventory('inventory-upstream.py')
        inventory('inventory-dialog-controls.py')
        files = root / 'docs/upstream-files.csv'
        dialogs = root / 'docs/upstream-dialogs.csv'
        controls = root / 'docs/upstream-controls.csv'
        reviewed = rows(files); reviewed[0]['status'] = 'partial'; save(files, reviewed)
        reviewed = rows(dialogs); reviewed[0]['status'] = 'partial'; save(dialogs, reviewed)
        reviewed = rows(controls)
        for row in reviewed:
            row.update(status='partial-native', native_mapping='Native fixture', notes='Original review')
        save(controls, reviewed)
        snapshots = {p: p.read_bytes() for p in [files, dialogs, controls]}
        # Dirty resources must never be read as content of the recorded commit.
        resource.write_text(old.replace('IDD_FIXTURE', 'IDD_DIRTY').replace('Pinned caption', 'Dirty caption'))
        inventory('inventory-upstream.py'); inventory('inventory-dialog-controls.py')
        assert all(p.read_bytes() == expected for p, expected in snapshots.items())
        # An advanced HEAD is not authorization to silently change the pin.
        new = old.replace('Pinned caption', 'New caption').replace('Old action', 'New action')
        resource.write_text(new); git('add', '.'); git('commit', '-m', 'advanced')
        advanced = git('rev-parse', 'HEAD')
        resource.write_text(old.replace('IDD_FIXTURE', 'IDD_UNCOMMITTED'))
        inventory('inventory-upstream.py'); inventory('inventory-dialog-controls.py')
        assert json.loads((root / 'docs/upstream.json').read_text())['commit'] == pinned
        assert all(p.read_bytes() == expected for p, expected in snapshots.items())
        # Explicit repinning reads that commit even with a different working copy.
        inventory('inventory-upstream.py', '--ref', advanced)
        inventory('inventory-dialog-controls.py')
        assert json.loads((root / 'docs/upstream.json').read_text())['commit'] == advanced
        assert rows(files)[0]['status'] == 'upstream-changed-needs-review'
        assert rows(dialogs)[0]['caption'] == 'New caption'
        assert rows(dialogs)[0]['status'] == 'upstream-changed-needs-review'
        changed, unchanged = rows(controls)
        assert changed['label'] == 'New action' and changed['status'] == 'upstream-changed-needs-review'
        assert changed['native_mapping'] == 'Native fixture' and 'requires review' in changed['notes']
        assert unchanged['status'] == 'partial-native' and unchanged['notes'] == 'Original review'
        # Repeating generation preserves the new audit without duplicating notes.
        final = {p: p.read_bytes() for p in [files, dialogs, controls]}
        inventory('inventory-upstream.py'); inventory('inventory-dialog-controls.py')
        assert all(p.read_bytes() == expected for p, expected in final.items())
        # Shared .rc2 resources are executable UI specifications too.
        shared = upstream / 'src/Shared.rc2'
        shared.write_text(old.replace('IDD_FIXTURE', 'IDD_SHARED').replace('Pinned caption', 'Shared Find'))
        git('add', 'src/Shared.rc2'); git('commit', '-m', 'shared resource')
        inventory('inventory-upstream.py', '--ref', git('rev-parse', 'HEAD'))
        inventory('inventory-dialog-controls.py')
        assert len(rows(dialogs)) == 2 and any(r['id'] == 'IDD_SHARED' and r['caption'] == 'Shared Find' for r in rows(dialogs))
        assert len([r for r in rows(controls) if r['dialog'] == 'IDD_SHARED']) == 2
        shared_snapshot = {p: p.read_bytes() for p in [files, dialogs, controls]}
        shared.write_text(old.replace('IDD_FIXTURE', 'IDD_DIRTY_SHARED'))
        inventory('inventory-upstream.py'); inventory('inventory-dialog-controls.py')
        assert all(p.read_bytes() == expected for p, expected in shared_snapshot.items())
    print('Pinned inventory: dirty checkout, advanced HEAD, explicit repin, review invalidation, unchanged mapping, idempotence and shared .rc2 coverage passed.')


if __name__ == '__main__':
    main()
