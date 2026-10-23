"""Measured peer bundle identity and explicit offline build parameters."""
from pathlib import Path
import plistlib
import re


def build_number(value):
    """Current CFBundleVersion numeric grammar; zero is an allowed component.

    Do not impose obsolete component digit limits or infer monotonicity against
    App Store Connect. The requested complete string is retained and compared.
    """
    if not isinstance(value, str) or re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', value) is None:
        raise ValueError('Build number must contain one to three numeric components separated by periods.')
    return value


def positive_jobs(value):
    if isinstance(value, bool):
        raise ValueError('Jobs must be a positive integer.')
    try:
        result = int(value)
    except (TypeError, ValueError):
        raise ValueError('Jobs must be a positive integer.') from None
    if result <= 0 or str(result) != str(value):
        raise ValueError('Jobs must be a positive integer.')
    return result


def application_identity(app, expected_build_number=None):
    """Require app/Finder/cache to carry the same measured version and build."""
    app = Path(app).resolve(strict=True)
    if expected_build_number is not None:
        build_number(expected_build_number)
    members = {
        'application': app,
        'finder': app / 'Contents/PlugIns/TurtleGitFinder.appex',
        'cache': app / 'Contents/Library/LaunchServices/TurtleGitCache.app',
    }
    measured = {}
    for role, bundle in members.items():
        path = bundle / 'Contents/Info.plist'
        if path.is_symlink() or not path.resolve(strict=True).is_relative_to(app):
            raise ValueError('Bundle identity metadata escapes its application or is an alias: ' + role)
        info = plistlib.loads(path.read_bytes())
        identity = {name: info.get(key) for name, key in [
            ('bundle_identifier', 'CFBundleIdentifier'),
            ('marketing_version', 'CFBundleShortVersionString'),
            ('build_number', 'CFBundleVersion'),
        ]}
        if not all(isinstance(value, str) and value for value in identity.values()):
            raise ValueError('Incomplete measured bundle identity: ' + role)
        build_number(identity['build_number'])
        measured[role] = identity
    main = measured['application']
    for role in ('finder', 'cache'):
        peer = measured[role]
        if peer['bundle_identifier'] != main['bundle_identifier'] + '.' + role:
            raise ValueError('Application/peer bundle identifier mismatch: ' + role)
        if any(peer[key] != main[key] for key in ('marketing_version', 'build_number')):
            raise ValueError('Application/peer version or build mismatch: ' + role)
    if expected_build_number is not None and main['build_number'] != expected_build_number:
        raise ValueError('Requested build number does not match measured application identity.')
    return {**main, 'peers': {role: measured[role] for role in ('finder', 'cache')}}
