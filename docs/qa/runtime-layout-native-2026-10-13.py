#!/usr/bin/env python3
"""Private signed-copy acceptance and negative seal/link checks; never launches a GUI."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'scripts'))
from runtime_bundle_layout import audit_layout,code_record
app=Path(sys.argv[1]).resolve()
assert app.parent==ROOT/'build/qa/runtime-layout-signed-2026-10-13', 'Use the owned QA copy only'
contents=app/'Contents';descriptor=json.loads((contents/'Resources/runtime-layout.json').read_text())
count=audit_layout(app)
assert count==len(descriptor['code']) and count>0
verify=['codesign','--verify','--deep','--strict',str(app)]
subprocess.run(verify,check=True)
# Prove the app seal covers reconstruction data, the original signing blocker.
source=contents/'Resources/TurtleGitRuntimes/Lexilla/Sources/build/Sources/TurtleGitLexilla/Scintilla/Scintilla.h'
original=source.read_bytes()
try:
    source.write_bytes(original+b'\n/* private QA seal mutation */\n')
    assert subprocess.run(verify,capture_output=True).returncode!=0, 'Reconstruction data was not sealed'
finally:source.write_bytes(original)
subprocess.run(verify,check=True)
# The compatibility path must not silently dispatch a different valid helper.
alias=contents/'Resources/TurtleGitRuntimes/EditorConfig/editorconfig';link=os.readlink(alias)
try:
    alias.unlink();alias.symlink_to(contents/'Helpers/IssueRegex/issue-regex')
    try:code_record(alias,alias.parent)
    except AssertionError:pass
    else:raise AssertionError('A substituted executable link was accepted')
finally:
    alias.unlink();alias.symlink_to(link)
subprocess.run(verify,check=True)
# Unknown links escaping a runtime must be rejected, even inside the same app.
unowned=contents/'Resources/TurtleGitRuntimes/EditorConfig/unowned-qa-link'
try:
    unowned.symlink_to(contents/'Helpers/IssueRegex/issue-regex')
    try:audit_layout(app)
    except AssertionError:pass
    else:raise AssertionError('An undeclared executable link was accepted')
finally:unowned.unlink()
subprocess.run(verify,check=True)
# Re-finalizing a complete layout must preserve payloads and the app seal.
before=hashlib.sha256((contents/'Resources/runtime-layout.json').read_bytes()).hexdigest()
subprocess.run([sys.executable,str(ROOT/'scripts/finalize-runtime-layout.py'),str(app)],env=dict(os.environ,CODE_SIGNING_ALLOWED='NO'),check=True)
assert hashlib.sha256((contents/'Resources/runtime-layout.json').read_bytes()).hexdigest()==before
subprocess.run(verify,check=True)
print(f'{count} code items; sealed reconstruction data; substituted/undeclared links rejected; repeat finalization preserved signed copy. No GUI launched.')
