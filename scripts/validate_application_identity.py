#!/usr/bin/env python3
"""Validate custom application/document artwork and alternate patch declaration."""
import hashlib, json, plistlib, struct, sys, zlib
from pathlib import Path
from functools import lru_cache

PNG = b'\x89PNG\r\n\x1a\n'
UPSTREAM = {
    'Upstream/Tortoise.ico': 'dd7d0bb42b72d565723cdaf0687ed3ce5afd30ef743248d35cac78532e4e6eac',
    'Upstream/TortoiseUDiff.ico': '8678b929d02355e510b77adbcee99a4cbc5ced1673df952d6a50e8f70005b242',
}

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()

@lru_cache(maxsize=24)
def png_pixels(data):
    """Read actual alpha/pixels with stdlib only; ImageIO emits noninterlaced RGBA8."""
    assert data[:8] == PNG, 'Not a PNG'
    offset, compressed, header = 8, bytearray(), None
    while offset < len(data):
        length, = struct.unpack_from('>I', data, offset)
        kind, payload = data[offset+4:offset+8], data[offset+8:offset+8+length]
        assert len(payload) == length and offset+12+length <= len(data), 'Truncated PNG chunk'
        if kind == b'IHDR': header = struct.unpack('>IIBBBBB', payload)
        if kind == b'IDAT': compressed.extend(payload)
        offset += length+12
        if kind == b'IEND': break
    assert header is not None
    width, height, depth, color, compression, filtering, interlace = header
    assert depth == 8 and color in (4, 6) and (compression, filtering, interlace) == (0, 0, 0), 'Expected transparent RGBA/gray-alpha8 PNG'
    channels = 4 if color == 6 else 2
    stride, raw = width*channels, zlib.decompress(compressed)
    assert len(raw) == height*(stride+1), 'PNG raster length mismatch'
    previous, result, pos = bytearray(stride), bytearray(), 0
    def paeth(a, b, c):
        p = a+b-c; pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
        return a if pa <= pb and pa <= pc else b if pb <= pc else c
    for _ in range(height):
        method, row = raw[pos], bytearray(raw[pos+1:pos+1+stride]); pos += stride+1
        assert method in range(5)
        if method == 1:
            for index in range(channels, stride): row[index] = (row[index]+row[index-channels]) & 255
        elif method == 2:
            row = bytearray((value+previous[index]) & 255 for index, value in enumerate(row))
        elif method in (3, 4):
            for index in range(stride):
                left = row[index-channels] if index >= channels else 0
                up = previous[index]
                prediction = (left+up)//2 if method == 3 else paeth(left, up, previous[index-channels] if index >= channels else 0)
                row[index] = (row[index]+prediction) & 255
        result.extend(row); previous = row
    if channels == 2:
        result = bytearray(channel for index in range(0, len(result), 2) for channel in (result[index], result[index], result[index], result[index+1]))
    return width, height, bytes(result)

def transparent_png(path, expected=None):
    width, height, pixels = png_pixels(path.read_bytes())
    if expected is not None: assert (width, height) == expected, (path, width, height)
    alpha = pixels[3::4]
    assert 0 in alpha and max(alpha) > 0, f'Missing real transparency or painted artwork: {path}'
    return width, height, pixels

def document_frames(data, images):
    """Modern PNG ICNS frames must contain the same custom catalog artwork."""
    assert data[:4] == b'icns' and struct.unpack_from('>I', data, 4)[0] == len(data)
    offset, matched = 8, set()
    while offset < len(data):
        kind, length = data[offset:offset+4], struct.unpack_from('>I', data, offset+4)[0]
        assert length >= 8 and offset+length <= len(data), 'Truncated ICNS element'
        payload = data[offset+8:offset+length]
        if payload.startswith(PNG):
            width, height, pixels = png_pixels(payload)
            assert width == height and width in images and pixels == images[width], ('Document frame differs from custom artwork', kind, width)
            matched.add(width)
        offset += length
    assert {512, 1024} <= matched, 'Custom high-resolution document frames absent'

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
    document = resources/'Branding/TurtleGitPatch.icns'
    assert (resources/declaration['CFBundleTypeIconFile']).read_bytes() == document.read_bytes()
    exported = next(x for x in info['UTExportedTypeDeclarations'] if x['UTTypeIdentifier'] == 'org.turtlegit.unified-diff')
    assert set(exported['UTTypeTagSpecification']['public.filename-extension']) == {'patch', 'diff'}
    source = root/'Sources/TurtleGitMac/Resources/Branding'
    manifest = json.loads((source/'provenance.json').read_text())
    assert manifest['schema'] == 2
    assert json.loads((resources/'Branding/provenance.json').read_text()) == manifest
    artwork = json.loads((source/'TurtleGitIconSource.provenance.json').read_text())
    assert manifest['artwork'] == artwork and artwork['asset'] == 'TurtleGitIconSource.png'
    assert all(isinstance(artwork[key], str) and artwork[key].strip() for key in ('prompt', 'generator', 'license'))
    assert digest(source/artwork['asset']) == artwork['sha256']
    width, height, _ = transparent_png(source/artwork['asset'])
    assert width == height and 1024 <= width <= 4096 and (artwork['width'], artwork['height']) == (width, height)
    assert manifest['sources'] == [{'asset': artwork['asset'], 'sha256': artwork['sha256'], 'kind': 'custom_generated_artwork'}]
    for asset in manifest['sources']:
        assert digest(resources/'Branding'/asset['asset']) == asset['sha256']
    assert json.loads((resources/'Branding/TurtleGitIconSource.provenance.json').read_text()) == artwork
    upstream = manifest['vendored_upstream']
    assert upstream['repository'] == 'https://github.com/TortoiseGit/TortoiseGit' and upstream['commit'] == '7338078f8ddd924b8cddee35f512f2286072136d'
    assert {entry['asset']: entry['sha256'] for entry in upstream['sources']} == UPSTREAM
    for entry in upstream['sources']:
        assert entry['active_branding'] is False and digest(source/entry['asset']) == UPSTREAM[entry['asset']]
        assert digest(resources/'Branding'/entry['asset']) == UPSTREAM[entry['asset']]
    for path, expected in manifest['outputs'].items():
        assert digest(root/path) == expected, path
    assert (resources/'Branding/UPSTREAM-ICON-LICENSE.txt').read_bytes() == (source/'UPSTREAM-ICON-LICENSE.txt').read_bytes()
    assert (resources/'Branding/ApplicationIcon.png').read_bytes() == (source/'ApplicationIcon.png').read_bytes()
    transparent_png(source/'ApplicationIcon.png', (1024, 1024))
    assets = root/'Sources/TurtleGitMac/Resources/ApplicationAssets.xcassets/AppIcon.appiconset'
    choices = json.loads((assets/'Contents.json').read_text())['images']; assert len(choices) == 10
    assert {(x['size'], x['scale']) for x in choices} == {(f'{size}x{size}', f'{scale}x') for size in (16, 32, 128, 256, 512) for scale in (1, 2)}
    images = {}
    for choice in choices:
        size = int(choice['size'].split('x')[0])*int(choice['scale'][0])
        _, _, pixels = transparent_png(assets/choice['filename'], (size, size))
        if size in images: assert images[size] == pixels, 'Equal-size icon slots differ'
        images[size] = pixels
    assert png_pixels((source/'ApplicationIcon.png').read_bytes())[2] == images[1024]
    document_frames(document.read_bytes(), images)
    assert document.read_bytes() == (source/'TurtleGitPatch.icns').read_bytes()
    assert (root/'docs/site/assets/application-icon.png').read_bytes() == (assets/'icon_256x256.png').read_bytes()
    assert (root/'docs/site/assets/application-favicon.png').read_bytes() == (assets/'icon_32x32.png').read_bytes()
    transparent_png(root/'docs/site/assets/application-icon.png', (256, 256))
    transparent_png(root/'docs/site/assets/application-favicon.png', (32, 32))
    shared = app/'Contents/Frameworks/TurtleGitCore.framework/Resources/Icons/TurtleGitApplication.png'
    assert shared.read_bytes() == (root/'Sources/TurtleGitCore/Resources/Icons/TurtleGitApplication.png').read_bytes()
    assert shared.read_bytes() == (assets/'icon_512x512.png').read_bytes(), 'Native branding differs from 512px custom artwork'
    transparent_png(shared, (512, 512))
    blame = app/'Contents/Frameworks/TurtleGitCore.framework/Resources/Icons/TurtleGitBlame.png'
    assert blame.read_bytes() == (root/'Sources/TurtleGitCore/Resources/Icons/TurtleGitBlame.png').read_bytes()
    transparent_png(blame, (512, 512))
    assert blame.read_bytes() != shared.read_bytes(), 'Attribution command lost its magnifier cue'

    print(f'Application/document identity: custom source/prompt provenance, transparent 1024/512px branding, ten macOS icon slots, compiled catalog/ICNS and alternate patch/diff handler verified: {app}')

if __name__ == '__main__': validate(Path(sys.argv[1]))
