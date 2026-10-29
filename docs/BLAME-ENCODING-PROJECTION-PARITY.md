# Blame encoding without rereading history

This partial family review uses pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`. In
`src/TortoiseGitBlame/TortoiseGitBlameView.cpp`, `OnChangeEncode` calls
`UpdateInfo`; `TortoiseGitBlameData.cpp`'s `UpdateEncoding` reinterprets retained
`m_RawLines`. Choosing a codec does not rerun attribution or rebuild the log.
Explicit codec selection is not a persisted global default in that source.

TurtleGit now separates a byte-backed annotation document from its decoded
presentation. Initial loading captures the pinned blob, exact porcelain source
payloads and attribution once, then reads the associated history and decorations.
A codec choice projects that retained document on an owned background worker.
It does not invoke Git, apply pending detection thresholds, recapture HEAD,
reapply filters, reread issue settings or replace history/reference metadata.
Reload and changes to attribution options still acquire a new document.

A failed automatic or explicit decode retains validated bytes and annotations.
The source pane clears rather than showing text under an incorrect codec
checkmark. The Encoding menu can recover using another explicit codec without
another repository read. History, selected original line and selected log hashes
remain attached to the accepted document. File Open and Recent Files retain the
same recovery route when a valid tracked file needs a legacy codec; failed
repository acquisition continues to report an error without replacing the old
file. Previous-revision navigation keeps its established explicit encoding and
attribution-option inheritance.

Cancellation and retirement invalidate late projection results and keep the
worker in the existing active-operation drain until it actually returns. Closing
or replacing a viewer cannot publish projected text into its successor. The
repository lease remains owned through that drain. Busy, blocking-child and
retired commands retain their existing admission gates.

The byte document validates attribution framing, exact source-byte equality and
line numbering independently of text decoding. Legacy codecs decode the complete
source to retain shift state. Existing UTF-16 line-boundary and binary refusals
remain: accepting raw annotations is not permission to display invalid text.

## Remaining differences and acceptance

Automatic still recognizes UTF-8 and supported UTF-16 forms. Windows falls back
to its active ANSI code page (`GetACP`); macOS has no equivalent Windows machine
code-page setting. TurtleGit retains explicit legacy selection rather than guessing
a locale or introducing a global preference absent upstream. This policy
boundary is not claimed resolved by the projection change.

The [dated evidence](qa/blame-encoding-projection-2026-10-29.json) records
41 focused Core methods with zero failures and the grouped native workflow with
system and bundled Git passing. It checks exact native text including the final
newline, annotation-row recovery, selected source-line preservation, no additional
Git calls, metadata continuity and actual cancellation/retirement drain. Both final
receivers were independently confirmed absent after reaping.

The initial native receiver crashed in AppKit observation; its cause remains
unproven. A later attempt exposed a fixture expectation that omitted the source's
final newline. The record retains both failed attempts, the source-cache repair,
the fixture changes and the final passes; it does not classify the crash as a
proven fixture-only problem. Physical menu
and VoiceOver acceptance, current signed-build execution, complete hosted CI and
whole Blame parity remain separate. Installed build31 predates this change.
