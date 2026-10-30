#!/usr/bin/env python3
"""Check unsigned build packaging; does not assert signing or sandbox activation."""
from validate_application_identity import validate as validate_identity
from runtime_bundle_layout import audit_layout
from bundle_architectures import audit_application_architectures
import argparse
import hashlib
import json
import pathlib
import plistlib
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('app', type=pathlib.Path)
parser.add_argument('--require-git', action='store_true', help='Require and audit a packaged App Store Git runtime.')
parser.add_argument('--require-universal', action='store_true', help='Require arm64 and x86_64 in all app-owned executable/framework targets.')
args = parser.parse_args()
app = args.app
validate_identity(app)
if args.require_universal or args.require_git:
    print("Universal application code verified:", audit_application_architectures(app))
print("Production runtime code/data layout verified:",audit_layout(app))
root = pathlib.Path(__file__).resolve().parent.parent
with (app / 'Contents/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
assert isinstance(info.get('NSAppleEventsUsageDescription'), str) and info['NSAppleEventsUsageDescription'].strip()
for name in ['App.entitlements', 'AppStore.entitlements']:
    with (root / 'Configuration' / name).open('rb') as stream:
        entitlements = plistlib.load(stream)
    assert entitlements['com.apple.security.automation.apple-events'] is True
    assert entitlements['com.apple.security.scripting-targets'] == {'com.apple.mail': ['com.apple.mail.compose']}
    expected = ['com.microsoft.Word', 'com.microsoft.Excel', 'com.microsoft.Powerpoint'] if name == 'AppStore.entitlements' else None
    assert entitlements.get('com.apple.security.temporary-exception.apple-events') == expected
    keys = {key for key in entitlements if key.startswith('com.apple.security.temporary-exception.apple-events')}
    assert keys == ({'com.apple.security.temporary-exception.apple-events'} if expected else set())
assert info['CFBundleIdentifier'] == 'org.turtlegit.macos'
assert (app / 'Contents/MacOS' / info['CFBundleExecutable']).is_file()
resources = app / 'Contents/Resources'
assert (resources / 'LICENSE').is_file() and (resources / 'NOTICE').is_file()
subprocess.run(['/usr/bin/python3', str(root / 'scripts/index-help.py'), '--verify', str(app)], check=True)
localization = json.loads((resources / 'LocalizationManifest.json').read_text())
assert localization['schema'] == 1 and localization['keys'] > 0
assert (resources / 'LocalizationCredits.txt').is_file()
def compiled_strings(path):
    # CopyStringsFile can emit UTF-16 XML with its original UTF-8 declaration.
    # Use the system parser for supported Apple string-table encodings.
    return plistlib.loads(subprocess.check_output(['/usr/bin/plutil', '-convert', 'xml1', '-o', '-', str(path)], stderr=subprocess.PIPE))
english = compiled_strings(resources / 'en.lproj/Localizable.strings')
assert len(english) == localization['keys'] and all(key == value for key, value in english.items())
for language in localization['languages']:
    path = resources / (language['id'] + '.lproj') / 'Localizable.strings'
    assert path.is_file(), 'Missing compiled localization: ' + language['id']
    table = compiled_strings(path)
    assert isinstance(table, dict) and len(table) == language['translated_keys'], language['id']
print('Pinned native label localizations verified:', len(localization['languages']) + 1, 'languages including English')

framework = app / 'Contents/Frameworks/TurtleGitCore.framework'
smtp = app / 'Contents/Frameworks/TurtleGitSMTP.framework/TurtleGitSMTP'
assert smtp.is_file(), 'Configured SMTP framework missing'
architectures = subprocess.check_output(['/usr/bin/lipo', '-archs', str(smtp)], text=True).split()
for architecture in architectures:
    smtp_links = subprocess.check_output(['/usr/bin/otool', '-arch', architecture, '-L', str(smtp)], text=True).splitlines()[1:]
    assert any('/usr/lib/libcurl.' in line for line in smtp_links), 'SMTP must use SDK system libcurl in ' + architecture
    for line in smtp_links:
        path = line.strip().split(' ', 1)[0]
        assert path.startswith(('@rpath/TurtleGitSMTP.framework/', '/usr/lib/', '/System/Library/')), path
    core_links = subprocess.check_output(['/usr/bin/otool', '-arch', architecture, '-L', str(framework / 'TurtleGitCore')], text=True)
    assert any(line.strip().split(' ', 1)[0].startswith('@rpath/TurtleGitSMTP.framework/') and line.strip().split(' ', 1)[0].endswith('/TurtleGitSMTP') for line in core_links.splitlines()[1:]), architecture
if args.require_git:
    assert {'arm64', 'x86_64'} <= set(architectures), architectures
wcrev = app / 'Contents/MacOS/TurtleGitWCRev'
assert wcrev.is_file() and wcrev.stat().st_mode & 0o111, 'WCRev utility missing'
wcrev_manifest = json.loads((resources / 'wcrev-provenance.json').read_text())
for name, digest in wcrev_manifest['sources'].items():
    assert hashlib.sha256((root / name).read_bytes()).hexdigest() == digest, name
wcrev_architectures = subprocess.check_output(['/usr/bin/lipo', '-archs', str(wcrev)], text=True).split()
assert set(architectures) <= set(wcrev_architectures), wcrev_architectures
for architecture in wcrev_architectures:
    links = subprocess.check_output(['/usr/bin/otool', '-arch', architecture, '-L', str(wcrev)], text=True).splitlines()[1:]
    assert any('@rpath/TurtleGitCore.framework/' in line for line in links), architecture
    for line in links:
        dependency = line.strip().split(' ', 1)[0]
        assert dependency.startswith(('@rpath/TurtleGitCore.framework/', '/usr/lib/', '/System/Library/')), dependency
    commands = subprocess.check_output(['/usr/bin/otool', '-arch', architecture, '-l', str(wcrev)], text=True)
    assert '@executable_path/../Frameworks' in commands, architecture
print('Packaged WCRev utility architecture, framework lookup and source provenance verified')
icons = framework / 'Resources/Icons'
manifest = json.loads((root / 'Sources/TurtleGitCore/Resources/Icons/provenance.json').read_text())
for asset in manifest['assets']:
    assert hashlib.sha256((icons / asset['asset']).read_bytes()).hexdigest() == asset['sha256'], asset['asset']
assert (icons / 'UPSTREAM-ICON-LICENSE.txt').is_file()
completion = framework / 'Resources/Completion'
completion_manifest = json.loads((root / 'Sources/TurtleGitCore/Resources/Completion/provenance.json').read_text())
assert json.loads((completion / 'provenance.json').read_text()) == completion_manifest
for asset in completion_manifest['assets']:
    assert hashlib.sha256((completion / asset['asset']).read_bytes()).hexdigest() == asset['sha256'], asset['asset']
extension = app / 'Contents/PlugIns/TurtleGitFinder.appex'
with (extension / 'Contents/Info.plist').open('rb') as stream:
    finder = plistlib.load(stream)
assert finder['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.FinderSync'
assert (extension / 'Contents/MacOS' / finder['CFBundleExecutable']).is_file()
print(f'App, embedded Finder extension, licenses and all {len(manifest["assets"])} upstream icon resources verified.')

if args.require_git:
    import subprocess
    subprocess.run(['/usr/bin/python3', str(root / 'scripts/validate-git-runtime.py'), str(app / 'Contents/Helpers/Git'), '--require-lfs', '--require-svn'], check=True)

import subprocess
subprocess.run(['/usr/bin/python3', str(root / 'scripts/validate-editorconfig-runtime.py'), str(app / 'Contents/Helpers/EditorConfig')], check=True)
subprocess.run(['/usr/bin/python3', str(root / 'scripts/validate-lexilla-runtime.py'), str(app / 'Contents/Helpers/Lexilla')], check=True)
subprocess.run(['/usr/bin/python3', str(root / 'scripts/validate-issue-regex-runtime.py'), str(app / 'Contents/Helpers/IssueRegex')], check=True)
if (app / 'Contents/Helpers/MergeDiff').is_dir():
    subprocess.run(['/usr/bin/python3', str(root / 'scripts/validate-merge-diff-runtime.py'), str(app / 'Contents/Helpers/MergeDiff')], check=True)
elif args.require_git:
    raise RuntimeError('A distribution bundle requires the Subversion merge adapter.')
subprocess.run(['/usr/bin/python3', str(root / 'scripts/validate-graph-layout-runtime.py'), str(app / 'Contents/Helpers/GraphLayout')], check=True)
subprocess.run(['/usr/bin/python3', str(root / 'scripts/validate-metafile-runtime.py'), str(app / 'Contents/Helpers/Metafile')], check=True)

askpass_arguments = ['/usr/bin/python3', str(root / 'scripts/validate-ssh-askpass.py'), str(app / 'Contents/Helpers/SSHAskpass/TurtleGitSSHAskpass')]
if args.require_git: askpass_arguments.append('--universal')
subprocess.run(askpass_arguments, check=True)

subprocess.run(['/usr/bin/python3', str(root / 'scripts/validate-openssh-runtime.py'), str(app / 'Contents/Helpers/OpenSSH')], check=True)
subprocess.run(['/usr/bin/python3', str(root / 'scripts/validate-putty-runtime.py'), str(app / 'Contents/Helpers/PuTTY')], check=True)

git_askpass = ["/usr/bin/python3", str(root / "scripts/validate-git-askpass.py"), str(app / "Contents/Helpers/GitAskpass/TurtleGitGitAskpass")]
if args.require_git: git_askpass.append("--universal")
subprocess.run(git_askpass, check=True)
