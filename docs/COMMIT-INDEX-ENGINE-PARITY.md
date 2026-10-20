# Commit checkbox index engine

Pinned upstream: `7338078f8ddd924b8cddee35f512f2286072136d`.
This family implements Commit's independently selected index-preparation engine,
not a replacement commit editor or a certification of the complete port.

## Source and native behavior

`Git.h::GIT_CMD_COMMIT_UPDATE_INDEX` is command 3, bit `0x8`. It is absent from
`DEFAULT_USE_LIBGIT2_MASK`; Add is command 10, bit `0x400`, enabled by default.
`CommitDlg.cpp::PrepareIndexForCommitWithoutStagingSupport` (1117–1277) reads
checked paths through `git_index_add_bypath`, removes checked deletions and old
rename names, and resets unchecked tracked rows to the comparison tree. Queued
unchecked additions/deletions are restored after Git progress according to
`ReaddUnselectedAddedFilesAfterCommit`. Git itself still creates the commit.

Native Commit captures its own preference store immediately after accepting the
Commit action, before status, issue questions, hooks and progress. Core also
captures an explicit/repository/default backend before preparation. Later Settings
changes cannot switch that accepted attempt. Explicit Add menu actions keep the
separate Add engine. Staging support commits its existing index, including partial
files; it never acquires this checkbox whole-file preparation policy. Existing
Replay Split preparation keeps its own workflow.

The library engine prepares the checked tree in an owned private index. Literal
NUL triples contain `add` or `remove`, the exact repository-relative path, and
`normal`, an explicitly retained staged mode, or the removal marker. The helper
accepts only those operations/modes, an absolute explicit private index and stdin.
It refuses malformed/unterminated/oversized plans, unsafe paths, live-index aliases,
symlinks, wrong ownership or permissions. Inputs are bounded to 32 MiB, 100,000
operations and 1 MiB per path. One write follows successful processing of the
whole plan. Existing Add and filtered checkout protocols retain their contracts.

Checked additions/modifications use the same source-priority one-shot clean driver
as Add, with built-in attributes, CRLF and ident ordering. Required failures stop
preparation; optional failures retain preceding filter output. Literal `%f` and
`%%`, repository working directory, captured Git configuration and private index
are retained. This source adapter does not implement persistent `filter.process`.
Ordinary status preflight still uses Git and can itself consult configured process
filters for modified tracked files; this family does not disable a repository's
filter configuration to conceal that boundary.

Git creates the commit against the prepared index without `--only` or another
working-file add. A separate copy reconciles the actual index by object metadata,
so clean filters do not run again just to publish selected entries. Exact Unicode
index neighbors, renamed names, deleted files with retained disk copies, symlink
and executable modes, unchecked staged entries, unborn repositories, parent-based
amendments, message-only and pending merges retain their existing native policies.
Explicit staged-mode preservation is an existing macOS workflow extension.

For the library engine, an owned real-index lock spans preparation and Git progress.
Library preparation failure or cancellation preserves the real index and HEAD.
The CLI engine instead publishes each completed source command group in order;
an earlier successful Add remains staged if a later tracked update fails. Both
paths reuse prepared index metadata without another explicit selected-file clean.
See the [conflicted selection family](COMMIT-CONFLICT-INDEX-PARITY.md) for the six
CLI phases, unchecked conflict resets and failure boundaries. After an attempted commit,
source checkbox restoration uses a fresh owned cancellation lifetime; restoration
failure is reported as a warning. Publication preserves the original index mode.
A failed hook or interrupted Git commit can retain source-style staged effects;
completed commits or branch creation are not rolled back. Cancellation waits for
actual clean workers and their descendants before private files/grants retire.

## Evidence and remaining work

The final universal helper/Debug checks, 32 distinct focused Core methods across
the initial and affected repair runs, and the Commit/Blame native groups with
system and packaged Git passed. Actual failures and repairs remain in the record;
this scoped result is not a full hosted or whole-application certification.

[Grouped evidence](qa/commit-index-blame-details-2026-10-19.json) records the actual
checkpoint, including failures and focused repairs. Implementation alone is not a
passing check. The [Blame details family](BLAME-AUTHOR-DETAILS-PARITY.md) shares
this implementation/build checkpoint and has independent native evidence.

Complete hosted integration, external filters and Git hook combinations, signed
repository grants, physical input, source-perfect layout and App Store submission
remain open. Source command-mask consumers outside this family remain independent.
See [Commit](COMMIT-PARITY.md), [Add](ADD-INDEX-FILTERS-PARITY.md) and the
[engine guide](LIBGIT2-TRANSPORT.md).
