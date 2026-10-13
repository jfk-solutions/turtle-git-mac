"""Explicit inside-out signing inventory for independent Debug previews."""
from pathlib import Path
import plistlib

MACHO = {bytes.fromhex(value) for value in ('cffaedfe', 'feedfacf', 'cafebabe', 'bebafeca')}

def signing_plan(app, runtime_code=()):
    app = Path(app).resolve()
    contents = app / 'Contents'
    bundles = [app] + [path for path in app.rglob('*') if path.is_dir() and not path.is_symlink() and path.suffix in ('.framework', '.appex', '.app')]
    main_executables = set()
    for bundle in bundles:
        plist = bundle / ('Resources/Info.plist' if bundle.suffix == '.framework' else 'Contents/Info.plist')
        if not plist.is_file():
            raise ValueError(f'Code bundle lacks Info.plist: {bundle}')
        if not plist.resolve().is_relative_to(app):
            raise ValueError(f'Bundle metadata escapes the preview: {plist}')
        metadata = plistlib.loads(plist.read_bytes())
        name = metadata.get('CFBundleExecutable')
        if not isinstance(name, str) or not name or '\0' in name or name in ('.', '..') or '/' in name:
            raise ValueError(f'Invalid bundle executable: {bundle}')
        executable = bundle / name if bundle.suffix == '.framework' else bundle / 'Contents/MacOS' / name
        if not executable.is_file() or not executable.resolve().is_relative_to(app):
            raise ValueError(f'Bundle executable missing or escaping the preview: {executable}')
        main_executables.add(executable.resolve())
    runtime_code = set(runtime_code)
    payloads = []
    for path in sorted(app.rglob('*')):
        if not path.is_file() or path.is_symlink() or path.resolve() in main_executables:
            continue
        if path.is_relative_to(contents) and str(path.relative_to(contents)) in runtime_code:
            continue  # Their finalized signatures are bound to provenance hashes.
        with path.open('rb') as stream:
            if stream.read(4) in MACHO:
                payloads.append(path)
    # Auxiliary MacOS/framework dylibs must be sealed before their containers.
    return payloads, sorted(bundles, key=lambda path: (-len(path.parts), str(path)))
