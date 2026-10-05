# Commit code-symbol completion audit

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
This work implements the definition parser, capture engine, text detection and
decoding, changed-file scanner and native Commit popup integration. The whole
application and Commit editor remain partial ports; signed sandbox acceptance
and complete Windows decoding equivalence are still unproven.

## Implemented source mapping

- CommitDlg.cpp::ParseRegexFile → MessageCodeDefinitions.overlay: first-position
  comments, comma-separated extension keys, user-over-shipped replacement,
  trimmed regex values and the original key/eqpos behavior.
- CommitDlg.cpp::ScanFile regex loop → helper `--code-captures`: C++ std::wregex,
  ECMAScript plus icase, every nonempty capture group rather than full matches.
- Captured CString keys → MessageCodeSymbols.captures: literal UTF-16 identity,
  deduplication and ordering, retaining original capture spelling.
- Shipped autolist.txt → unchanged Completion resource with Git blob
  `4115a7a301b9a209613e7b458ee2215cd205f5d4` and SHA-256 provenance.

The helper searches an explicit decoded file length, unlike its issue-matching
mode's null-terminated CString input. A captured group is then truncated at its
first NUL, matching ScanFile's c_str insertion. The helper reports UTF-16 ranges
rather than passing candidate strings through an escaping protocol. Existing
validation and UTF-8 styling modes retain their previous behavior.

The source does not enable regex multiline mode. In particular, '^' matches the
beginning of the decoded file, not each line. Regexes with no captures contribute
no symbols; empty optional captures are skipped. Invalid expressions fail the
capture API; the file scanner silently skips them as source does.

## Source quirks retained

Only the last extension key is trimmed directly. Earlier keys before commas are
inserted verbatim; a key with a trailing space therefore does not match a normal
file extension. The parser also retains the original '=' offset while repeatedly
shortening the line. With a sufficiently long first extension and a comma inside
the regex, that retained offset can consume part of the regex as another key.
This behavior has an explicit regression fixture. Definition-key lowercasing and
whitespace classification use native Foundation rules; exact Windows locale
behavior remains under audit.

## Validation

Four code-symbol tests verify all captures, optional/empty groups, icase,
deduplication, no multiline anchors, UTF-16 offsets, explicit input NULs and
CString capture truncation, invalid ECMAScript, empty definitions, overrides,
untrimmed extension keys and the retained eqpos quirk.

The full local suite passed 397 tests with zero failures. Nineteen focused
tests also exercise existing issue matching/styles, filename
completion and snippets. Both arm64 and x86_64 helper slices pass protocol
fixtures for validation, styling and code captures. The complete bundled source
was copied into a fresh temporary directory, rebuilt and tested on both slices.
Unsigned Debug/App Store builds and helper/Git/resource audits passed. This does
not establish native scanner or signed sandbox acceptance.

See [recorded evidence](qa/commit-code-symbol-engine-2026-10-05.json).

## Changed-file scanner and native integration

MessageCodeScanner loads the unchanged shipped autolist.txt, then the private
user autolist.txt alongside snippet.txt. Commit Refresh reloads both. The shared
actor retains the first successfully scanned regex for each extension across
windows, matching the source's static extension cache. Invalid patterns are not
cached. A currently empty definition still disables parsing even with a cache
entry. The source caches a valid regex before matching; the native implementation
caches after helper success, so cancellation/helper-limit failures before that
point can differ and require further acceptance.

Snippets are inserted first. Each displayed row then inserts its full path and
slash suffixes (plus optional extension-free basename) before its code symbols.
This is **row-order insertion priority**, not a global filename-over-code rule:
a code symbol from an earlier row can retain its kind when a later filename has
the same UTF-16 spelling. Six scanner tests cover this and snippet collisions.

Ignored contents are skipped; unversioned contents require
AutocompleteParseUnversioned (default false). File names remain eligible.
AutocompleteParseMaxSize defaults to 300000 bytes; empty files, files at least
INT_MAX bytes and files exceeding the limit are skipped. The five-second
AutocompleteParseTimeout is checked before each row, using the source's strict
elapsed > budget condition. Definition loading precedes the traversal timer.
Cancellation is checked before loading, between rows and before publication.
A partial catalog after timeout is retained like source traversal.

Files are opened off the main actor, following symlinks and checking the target's
actual size/type with fstat. O_NONBLOCK and regular-file checks prevent FIFO/device
reads from blocking. The decoder's raw UTF-16 units enter the capture helper
without a Swift String round trip. Definitions use the existing native
UTF-8/UTF-16-BOM/Windows-1252 loading adaptation. The helper additionally bounds
execution/input/output; these safeguards can skip pathological files that Windows
would attempt. Definition loading itself is not covered by the content size gate.

The Commit model keeps a filename/snippet fallback while the scan runs, captures
the repository access lease for its whole operation and refuses sandbox scans
without the expected scope. Generation/cancellation checks discard stale scans
when displayed rows or saved scan options change. Refresh forces rescanning even
when paths are unchanged. Disabling Autocompletion cancels content scanning at
the next model update/Refresh, and the editor suppresses completion requests. The popup uses the catalog's recorded kind with the
original file.ico, code.ico or snippet.ico. Snippet expansion remains unchanged.

Native disposable-repository checks verified typed and Ctrl-Space requests,
Tab insertion of SymbolAlpha, keyboard selection of colliding SymbolBeta expanding
to its snippet, one Undo restoring the selected Sym prefix, unchecked-file symbols,
default unversioned-content exclusion, F5 replacement by SymbolRefreshed and mouse
acceptance. An immediate completion request after Undo correctly has no popup
while the restored prefix is selected. No Git commit was made.

The app screenshot command failed with an audio/video capture error; CUA's window
image clipped the external popover. Neither proves icon appearance. Subsequent
appearance menu observations became stale; normal Quit attempts could not finish,
and only the verified disposable QA PID was terminated. Process scan then found
no TurtleGit app. A second QA process was launched only after that cleanup,
with dark appearance requested at startup; its capture failed in the same way.
It verified Left/Right and Backspace without automatic popup reopening, typed
insertion reopening, paste without automatic popup, explicit Ctrl-Space after
paste, Tab/Shift-Tab focus transfer, and hiding an unversioned row removing its
filename candidate. That process quit normally through the draft confirmation,
and the final process scan was empty. Code-icon and dark popup appearance, saved scanner settings changes, interrupted
scan publication, complete keyboard behavior, both architectures and actual
signed sandbox helper/file access still need native acceptance.

The full scanner regression run passed 410 tests with zero failures; a subsequent
32-test focused run also passed after native catalog integration. Final unsigned
Debug and App Store builds and bundle audits include all 67 original icons.

See [scanner and popup evidence](qa/commit-code-scanner-2026-10-05.json).

## Isolated scanner encoding and decode-filter port

MessageCodeText.swift adapts FileTextLines.cpp::CheckUnicodeType and its decode
filters, with declarations from FileTextLines.h (blob
`ec857cb501cd1331aeb0b4e9d5dcf6ef6f405f6a`). It returns raw UTF-16 units rather
than normalizing through a Swift String. This module feeds the changed-file scanner; it does not change Blame or
merge-editor decoding.

The detector preserves aligned zero-dword rejection before BOM checks,
UTF-32/UTF-16/UTF-8 BOM ordering, minimum input lengths, the NUL-count threshold
and parity heuristic, structural UTF-8 continuation checks and default-false
UseUTF8 behavior. That structural check can classify overlong/surrogate UTF-8
sequences as UTF-8; modern scalar validation is deliberately not substituted.

Scanner decode filters retain the BOM as input text. UTF-16 LE/BE expose complete
16-bit units and ignore an incomplete trailing byte, retaining unpaired
surrogates. UTF-32 expands valid supplementary values to pairs, replaces values
at least 0x110000, ignores incomplete dword tails, and preserves the source's
length quirk: GetStringView exposes the input scalar count after pair expansion,
which can truncate later content or leave a final unpaired high surrogate.
The native decoder exposes that exact unit prefix.

Windows CP_ACP has no automatic macOS equivalent. The isolated API currently
accepts a caller-supplied Foundation legacy encoding, defaulting to Windows-1252.
UTF-8 decode uses native replacement decoding. Exact Windows ACP selection,
MB_PRECOMPOSED behavior, malformed UTF-8 replacement and user-facing settings
remain unproven and are required before complete scanner parity is claimed.

Seven tests verify binary alignment/BOM priority, short inputs/preferences,
NUL threshold/parity, structural UTF-8 quirks, UTF-16 raw/BOM/odd-tail behavior,
UTF-32 truncation/invalid values and explicit legacy adaptation. Nineteen focused
completion/code/snippet tests pass in total. The reproducible differential check
`scripts/check-message-code-text.py` extracts the pinned upstream detector,
compiles it with a minimal registry/type shim, and compares 12,010 generated
cases with Swift. Both UseUTF8 values and deterministic BOM/NUL/random-byte
inputs produced zero differences. This verifies those tested detector inputs;
it does not establish Windows decode-API equivalence or native UI acceptance.

See [decoder evidence](qa/commit-code-text-2026-10-05.json). No QA app was launched.
Changed-file scanning and raw-unit capture integration are now implemented as
described above. Complete Windows decoder equivalence, editor and signed sandbox
acceptance remain pending.
