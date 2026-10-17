#!/usr/bin/env python3
"""Validate packaged app/document icons and alternate patch-document declaration."""
import hashlib, json, plistlib, struct, sys
from pathlib import Path

def validate(app):
    root = Path(__file__).resolve().parent.parent
    resources = app/'Contents/Resources'
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    assert info['CFBundleIconName'] == 'AppIcon'
    icon = resources/Path(info['CFBundleIconFile']).with_suffix('.icns')
    assert icon.is_file() and icon.read_bytes()[:4] == b'icns', icon
    assert (resources/'Assets.car').is_file(), 'Compiled application catalog absent'
    documents = info['CFBundleDocumentTypes']; assert len(documents) == 1
    declaration = documents[0]
    assert declaration['CFBundleTypeRole'] == 'Editor' and declaration['LSHandlerRank'] == 'Alternate'
    assert declaration['LSItemContentTypes'] == ['org.turtlegit.unified-diff']
    assert set(declaration['CFBundleTypeExtensions']) == {'patch', 'diff'}
    assert (resources/declaration['CFBundleTypeIconFile']).read_bytes() == (resources/'Branding/TurtleGitPatch.icns').read_bytes()
    exported = next(x for x in info['UTExportedTypeDeclarations'] if x['UTTypeIdentifier'] == 'org.turtlegit.unified-diff')
    assert set(exported['UTTypeTagSpecification']['public.filename-extension']) == {'patch', 'diff'}
    source = root/'Sources/TurtleGitMac/Resources/Branding'
    manifest = json.loads((source/'provenance.json').read_text())
    assert json.loads((resources/'Branding/provenance.json').read_text()) == manifest
    for asset in manifest['sources']:
        assert hashlib.sha256((resources/'Branding'/asset['asset']).read_bytes()).hexdigest() == asset['sha256']
    for path, digest in manifest['outputs'].items():
        assert hashlib.sha256((root/path).read_bytes()).hexdigest() == digest, path
    assert (resources/'Branding/UPSTREAM-ICON-LICENSE.txt').read_bytes() == (source/'UPSTREAM-ICON-LICENSE.txt').read_bytes()
    assets = root/'Sources/TurtleGitMac/Resources/ApplicationAssets.xcassets/AppIcon.appiconset'
    choices = json.loads((assets/'Contents.json').read_text())['images']; assert len(choices) == 10
    for choice in choices:
        size = int(choice['size'].split('x')[0])*int(choice['scale'][0])
        data = (assets/choice['filename']).read_bytes()
        assert data[:8] == b'\x89PNG\r\n\x1a\n' and struct.unpack('>II', data[16:24]) == (size, size)
    assert (root/'docs/site/assets/application-icon.png').read_bytes() == (source/'ApplicationIcon.png').read_bytes()
    shared = app/'Contents/Frameworks/TurtleGitCore.framework/Resources/Icons/TurtleGitApplication.png'
    assert shared.read_bytes() == (resources/'Branding/ApplicationIcon.png').read_bytes(), 'Native branding differs from application artwork'
    assert shared.read_bytes() == (root/'Sources/TurtleGitCore/Resources/Icons/TurtleGitApplication.png').read_bytes()
    print(f'Application/document identity: ten macOS icon slots, compiled catalog/ICNS, source provenance and alternate patch/diff handler verified: {app}')

if __name__ == '__main__': validate(Path(sys.argv[1]))
