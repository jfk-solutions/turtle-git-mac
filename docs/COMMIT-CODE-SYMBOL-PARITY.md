# Commit code-symbol completion audit

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
This work implements the definition parser and capture engine. **Scanning changed
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
5. Port CFileTextLines::CheckUnicodeType plus the ASCII/UTF-8/UTF-16/UTF-32 filters,
   including binary rejection and Windows code-page decisions. The existing
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
