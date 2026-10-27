# Historical Git filenames and native history

This family extends the Browser namespace workflow against pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`. It is a partial workflow review,
not certification of Browser, Log, Blame or the whole port.

## Source behavior and native adaptation

`src/TortoiseProc/RepositoryBrowser.cpp:733–772,817–837` offers Show log for files
and folders and Blame for files when a working repository is available. Both
commands retain the Browser revision. The source decodes names into its Windows
string namespace; native Browser instead retains each original Git byte path,
including names that cannot be decoded as UTF-8, as documented in
[Browser filename handling](REPOSITORY-BROWSER-NAMESPACE-PARITY.md).

Previously those raw rows could be navigated and inspected as stored objects,
but history actions were refused. The connected native readers now pass exact
Git pathname bytes to the existing owned Git process. Only explicitly indexed
arguments receive a byte override. An escaped caption is diagnostic text; it is
never substituted for the Git filename, evaluated by a shell, or interpreted as
a macOS filesystem path. Embedded NUL and invalid argument indexes are refused.
All other arguments retain their original Unicode spelling and boundaries.

## Connected reads and presentation

File and directory Log reads retain ordinary revision walking, path scoping,
filters, mailmap, source metadata and optional rename following. Directory scopes
still refuse the file-only Follow renames mode. Actual parents, rewritten graph
parents and commit identities remain separate. Blame reads the pinned stored
blob and preserves original line bytes, attribution, renamed/copied origins and
its configured annotation/history choices.

Name-status, numstat and raw diff records preserve distinct pathname identities
instead of merging a raw name with a valid replacement-character sibling. The
selected libgit2 history backend carries the same validated opaque path keys;
the new path transport applies only to historical metadata. Transfer and native
filesystem notification contracts remain unchanged. Cache context is versioned
to prevent old lossy pathname records from being reused. Optional filesystem
attribute fingerprints refuse raw keys, so those records are read without that
cache rather than constructing an invalid native URL.

Browser menu receipts retain the pinned revision and exact path. Log/Blame
captions, origin labels and clipboard presentation use escaped names. Internal
keys do not become user-visible filenames, recent filesystem entries or syntax
loader paths. A late Browser or annotation callback cannot retarget another
repository or a retired owner. Owned history reads retain their cancellation,
process-group drainage, repository access and Quit protection.

## Verification and remaining boundaries

The [dated checkpoint](qa/raw-history-family-2026-10-27.json) records the actual
implementation and validation state. All 149 distinct relevant Core methods
passed cumulatively: the initial group caught an ordinary-path Blame admission
regression, then the nine affected ordinary/raw cases passed after restoring the
existing path checks. The universal helper, regenerated project/resources and
final unsigned Debug build passed.

All six Browser namespace cases passed with both system and bundled Git. The
first native run retained an old dispatch count; the corrected fixture preserves
its assertions and the failed/unrun cases passed without repeating the already
passing listing/navigation pair. The new history case checks actual native menu
selectors/icons, raw folder history, pinned reads after HEAD drops the raw names,
origin callbacks, display/copy/tooltip identity, filesystem refusal and held Git
read retirement. All 13 attempted receivers were reaped and independently absent.
There was no physical screenshot or signed deployment check. Earlier Browser
checks establish their dated families, not these new paths.

Raw original-path checkout, filtered comparison/materialization, filesystem
exports/promises, working-tree mutation and submodule checkout resolution remain
separate implementation work. Their path-dependent dispatchers refuse a raw key
instead of addressing a replacement spelling. Hash-only revision actions remain
independent of that restriction. Stored-object inspection and explicit unfiltered
delivery under a safe chosen filename remain available.

Physical gestures, VoiceOver, signed sandbox grants, external receiving
applications, Intel/minimum-OS execution, full hosted CI and complete source
visual parity require separate acceptance. No signed installation or App Store
submission is part of this checkpoint.
