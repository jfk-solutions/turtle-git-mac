# Commit template and operation-message decoding

Reference: pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
[`CGit::LoadTextFile`](https://github.com/TortoiseGit/TortoiseGit/blob/7338078f8ddd924b8cddee35f512f2286072136d/src/Git/Git.cpp#L3431),
[`CUnicodeUtils::GetUnicodeLength`](https://github.com/TortoiseGit/TortoiseGit/blob/7338078f8ddd924b8cddee35f512f2286072136d/src/Utils/UnicodeUtils.cpp#L228)
and the `GetUnicode` default code page in UnicodeUtils.h.

The source reads the complete file as bytes and converts with `CP_UTF8`, flags
zero. It does not auto-detect UTF-16 or use `i18n.commitencoding` for this input.
On modern Windows, malformed UTF-8 is replaced with U+FFFD, rather than causing
conversion to fail; see Microsoft's
[MultiByteToWideChar documentation](https://learn.microsoft.com/en-us/windows/win32/api/stringapiset/nf-stringapiset-multibytetowidechar).
The source has no BOM-removal step.

TurtleGit now uses UTF-8 replacement decoding and retains a leading U+FEFF.
CRLF becomes LF and trailing LF is normalized to one final newline. Empty files
therefore produce a single newline. The same reader handles `commit.template`,
`SQUASH_MSG` and `MERGE_MSG`; the operation files append in that order. ReCommit
uses the template-only seed. Missing or unreadable paths still produce a warning
while available operation messages remain usable. Input bytes are never rewritten.

The focused Core cases cover malformed lead/continuation bytes, an incomplete
sequence, BOM retention, CRLF, append order, template-only restoration, empty
files and actual directory/missing-path failures. A configured Windows-1252
commit-output encoding does not change template input decoding. Main/linked
worktree messages remain separate. Exact input, HEAD, raw index and config
invariants are checked where applicable.

The native history receiver loads an actual BOM/malformed-byte/CRLF template in
the Commit editor. With issue support enabled, its initial displayed message
trims LF as upstream `GetBugIDFromLog` does. The receiver explicitly restores the
raw template before checking history equality/replacement and Cancel. Its other
message insertion, issue-update and owned-sheet checks remain in place.

Exact Windows comparison for every malformed subsequence, embedded-NUL UI
behavior, physical entry, external-template authorization and signed sandbox
acceptance remain unverified. This is a partial Commit parity checkpoint.

Twenty focused Core tests and native checks with system and bundled Git passed.
Final unsigned Debug/AppStore builds and bundle audits passed with 116 original
icons, required AppStore runtimes and the updated loader attribution in NOTICE.
See [the QA record](qa/commit-template-decoding-2026-10-10.json).
