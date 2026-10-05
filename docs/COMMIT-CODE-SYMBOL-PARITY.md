# Commit code-symbol completion audit

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
This work implements the definition parser, capture engine and isolated text
detection/decoding. **Scanning changed
files and showing code symbols in the native Commit popup are not implemented
yet.** The whole application and Commit editor remain partial ports.

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
capture API; the future file scanner must silently skip them as source does.

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

## Required next implementation and acceptance

1. Load shipped definitions, then private user autolist.txt; reload on Commit
   Refresh. Preserve the source regex cache behavior or explicitly record any
   native adaptation before claiming parity.
2. Traverse all displayed file rows in order, adding filenames/suffixes before
   considering file-content parsing. Preserve snippet > filename > code priority.
3. Skip ignored contents; skip unversioned contents unless
   AutocompleteParseUnversioned is true (default false).
4. Apply AutocompleteParseTimeout (default five seconds) across traversal and
   AutocompleteParseMaxSize (default 300000 bytes). Empty files and files at least
   INT_MAX bytes are skipped. Decode only the source-supported text encodings.
5. Integrate the isolated CFileTextLines detector/filter port, resolve Windows
   ACP and malformed UTF-8 behavior, and feed raw UTF-16 units into capture
   transport without a lossy String conversion. The existing
   Blame decoder is not evidence for these distinct scanner rules. The pinned
   FileTextLines.cpp blob is `e9ac66ef889687750921f09d4ccafce7f843e996`:
   CheckUnicodeType first rejects aligned zero dwords, before testing BOMs,
   and then applies a NUL-count/parity heuristic for BOM-less UTF-16.
6. Run scanning off the editor thread, cancel/ignore stale repository or refresh
   results, and retain valid repository access for the complete operation.
7. Give code symbols the original IDI_CODE icon in the native popup and verify
   capture, filename/snippet collisions, unchecked and unversioned candidates,
   gates, timeout, Undo and light/dark appearance on disposable repositories.
8. Verify actual signed sandbox file access/helper inheritance and both supported
   architectures before distribution claims.

The existing helper process has bounded execution, output capture and input
sizes. Those native safeguards do not substitute for the source's traversal
settings or the still-unimplemented file scanner.

## Isolated scanner encoding and decode-filter port

MessageCodeText.swift adapts FileTextLines.cpp::CheckUnicodeType and its decode
filters, with declarations from FileTextLines.h (blob
`ec857cb501cd1331aeb0b4e9d5dcf6ef6f405f6a`). It returns raw UTF-16 units rather
than normalizing through a Swift String. This module is not connected to changed
file scanning yet; it does not change Blame or merge-editor decoding.

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
The complete file scanner, raw-unit capture integration, file-size/time gates,
regex cache and native popup/keyboard/signed sandbox acceptance remain pending.
