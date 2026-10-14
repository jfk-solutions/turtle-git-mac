"""Validate portable macOS archives and prepare explicit offline export settings."""
from pathlib import Path, PurePosixPath
import hashlib
import plistlib
import re
import subprocess
from bundle_architectures import APPLICATION_CODE

KIND = 'TurtleGitDistributionArchiveAudit'

def archive_application(archive):
    archive = Path(archive).resolve(strict=True)
    metadata_path = archive / 'Info.plist'
    if metadata_path.is_symlink(): raise ValueError('Archive metadata must not be a symlink.')
    metadata = plistlib.loads(metadata_path.read_bytes())
    properties = metadata.get('ApplicationProperties', {})
    relative = properties.get('ApplicationPath')
    if metadata.get('ArchiveVersion') != 2 or not isinstance(relative, str):
        raise ValueError('Not an application XCArchive with version 2 metadata.')
    parts = PurePosixPath(relative)
    if parts.is_absolute() or '..' in parts.parts or len(parts.parts) != 2 or parts.parts[0] != 'Applications' or parts.suffix != '.app':
        raise ValueError('Invalid archived application path.')
    app = archive / 'Products' / relative
    if not app.is_dir() or app.is_symlink() or not app.resolve().is_relative_to(archive):
        raise ValueError('Archived application missing or escaping the archive.')
    products = archive / 'Products'
    if set(p.name for p in products.iterdir()) != {'Applications'} or list((products / 'Applications').iterdir()) != [app]:
        raise ValueError('Archive contains extra installed products; review SKIP_INSTALL.')
    info_path = app / 'Contents/Info.plist'
    if info_path.is_symlink(): raise ValueError('Application metadata must not be a symlink.')
    info = plistlib.loads(info_path.read_bytes())
    pairs = [('CFBundleIdentifier','CFBundleIdentifier'), ('CFBundleShortVersionString','CFBundleShortVersionString'), ('CFBundleVersion','CFBundleVersion')]
    for source, target in pairs:
        value = info.get(source)
        if not isinstance(value, str) or not value or properties.get(target) != value:
            raise ValueError('Archive/application identity mismatch: ' + source)
    if info.get('CFBundlePackageType') != 'APPL': raise ValueError('Archived product is not an application.')
    return app, metadata, info

def uuid_map(path):
    output = subprocess.check_output(['xcrun','dwarfdump','--uuid',str(path)],text=True)
    result = {architecture: value.upper() for value, architecture in re.findall(r'UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)',output)}
    if not result: raise ValueError('No Mach-O UUIDs: ' + str(path))
    return result

def debug_symbols(archive, app):
    archive = Path(archive).resolve(strict=True)
    candidates = list((archive / 'dSYMs').glob('*.dSYM/Contents/Resources/DWARF/*'))
    indexed = {}
    for candidate in candidates:
        if not candidate.is_file() or candidate.is_symlink() or not candidate.resolve().is_relative_to(archive):
            raise ValueError('Invalid archived dSYM payload: ' + str(candidate))
        indexed.setdefault(candidate.name, []).append((candidate, uuid_map(candidate)))
    result = {}
    for relative in APPLICATION_CODE:
        binary = (app / relative).resolve(strict=True)
        values = uuid_map(binary)
        match = [(path, uuids) for path, uuids in indexed.get(Path(relative).name, []) if uuids == values]
        if len(match) != 1 or not {'arm64','x86_64'}.issubset(values):
            raise ValueError('Missing, duplicate or mismatched universal dSYM: ' + relative)
        result[relative] = {'uuids':values,'dsym':str(match[0][0].relative_to(archive))}
    return result

def file_inventory(archive):
    root = Path(archive).resolve(strict=True)
    result = {}
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            target = path.readlink()
            if target.is_absolute() or not path.resolve(strict=True).is_relative_to(root):
                raise ValueError('Nonportable or escaping archive alias: ' + relative)
            result[relative] = {'kind':'symlink','target':str(target)}
        elif path.is_file():
            digest = hashlib.sha256()
            with path.open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024*1024), b''): digest.update(chunk)
            result[relative] = {'kind':'file','size':path.stat().st_size,'mode':oct(path.stat().st_mode & 0o777),'sha256':digest.hexdigest()}
        elif not path.is_dir(): raise ValueError('Unsupported archive member: ' + relative)
    return result

def export_options(channel, team_id):
    if not re.fullmatch(r'[A-Z0-9]{10}', team_id or ''):
        raise ValueError('Supply the actual ten-character Apple team ID; no placeholder is generated.')
    if channel not in ('AppStore','Release'): raise ValueError('Unknown distribution channel.')
    return {'method':'app-store-connect' if channel == 'AppStore' else 'developer-id',
            'destination':'export','teamID':team_id,'signingStyle':'automatic',
            'manageAppVersionAndBuildNumber':False,'stripSwiftSymbols':True,'uploadSymbols':False}
