# Default to UTF-8 encoding

Baseline: `7338078f8ddd924b8cddee35f512f2286072136d`,
`FileTextLines.cpp::CheckUnicodeType`, `SetMainPage.cpp::UseUTF8` and
`IDD_SETMAINPAGE`.

Merge Editor General now includes the source **Default to UTF-8 encoding**
checkbox, default false, with shared Settings Apply/Cancel. It uses the same
source classifier already ported for commit-message completion scanning.
Seven-bit text normally loads as ASCII (Windows-1252); enabling the preference
selects UTF-8. BOM-marked Unicode and valid non-ASCII UTF-8 retain their formats.
The source's short-file quirk is retained: empty/one/two-byte files classify as
ASCII even when the preference is enabled. Strict decoding rejects malformed
Unicode and NUL/binary data rather than introducing replacement characters.

ASCII/legacy decoding uses the explicit existing Windows-1252 adapter. Legacy
bytes such as é can now open in native two-file and three-file viewers and save
in their detected encoding without changing input bytes or adding a BOM. Source
Windows ACP depends on the Windows locale; other legacy code pages remain open
work. Generic comparison decoding APIs keep their previous defaults. Conflict
and standalone three-way APIs opt into Merge classification only when supplied
with the new parameter.

The preference is captured when loading/reloading a document. Applying settings
does not silently reinterpret an existing draft or its output encoding. Explicit
Encoding choices still take priority for that open document and are retained
through Save. A reload detects the saved bytes again, as upstream does.
Commit completion scanning reads the same canonical preference, with the prior
`Merge.UseUTF8` key accepted only when `TurtleGitMerge.UseUTF8` is absent.

Focused Core checks cover ASCII/short files, source default precedence, Unicode
BOMs, valid non-ASCII UTF-8, legacy bytes, malformed/binary rejection, document
metadata/byte retention and exact legacy saves. Native checks cover the actual
checkbox Apply/Cancel, load/reload timing, two/three-pane legacy decoding and
standalone CP1252 output with inputs retained. Full physical settings/format
interaction, Windows locale equivalence, malformed-file compatibility,
all load callers, signed/minimum-OS and complete application acceptance remain
open. This page is still a partial source replacement.


## Evidence

The focused Core check passed four tests with zero failures after an initial
build-only local-name correction. The unsigned Debug build and all fifteen
Merge receiver families passed; one fixture compilation linked the existing
app objects and one process ran the checks. See
[the batch record](qa/merge-default-encoding-2026-10-12.json).
Owned windows/helpers closed. No full hosted/signed acceptance is claimed.
