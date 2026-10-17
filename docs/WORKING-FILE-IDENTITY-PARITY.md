# Working-file identity and metadata

Pinned source: `7338078f8ddd924b8cddee35f512f2286072136d`,
Git.cpp NUL-delimited status/diff readers and
GitStatusListCtrl.cpp::SetGitIndexFlagsForSelectedFiles. The latter looks up each
selected UTF-8 Git path independently in libgit2's index. Swift String equality
instead treats canonically equivalent Unicode spellings as equal, which is
unsuitable for Git index keys.

## Connected read/metadata and index-flag family — October 17, 2026

StatusEntry merges deleted/unversioned copies only for identical UTF-8 path bytes.
StatusEntry and CommitFile equality/hashing retain exact path and rename-source
spellings. The name-status/numstat/raw joins use exact destination keys, so a
canonical alias cannot inherit another file's statistics or submodule type.
Working Tree status, amend-to-parent Commit status and working-tree Log history
retain those keys while joining normal entries, index-only changes, per-path
flags and differences. Explicit row scope matching uses exact bytes. The common-
directory comparator is exact, but its input still comes from filesystem URLs;
full invocation spelling preservation remains open.

GitPathMap carries exact path metadata through Commit's staged/unstaged lists,
Working Tree, Revert, Rebase conflict snapshots, metadata columns, sorting and
clipboard text. Filesystem metadata can still describe one shared physical file
on filesystems that alias the two spellings; its Git keys remain separate.

Index-flag requests deduplicate exact spellings, look up exact stage-zero records
and retain exact updated/unavailable path reports. The locked private-index write
uses NUL-delimited stdin rather than argv, preserving Unicode spelling, leading
dashes, tabs and newlines without changing persistent Git configuration. Stage
objects and HEAD remain unchanged by flag updates.

Finder index flags use the same path map. Absolute metadata keys append the raw
Git suffix to the repository root string; passing that suffix through Foundation
URL path joining can normalize it on macOS and is avoided here. New snapshots include an `indexFlagsV2`
array of path/value records; current readers prefer it. The original `indexFlags`
object is also written deterministically for older installed extension/cache
readers. Old readers retain their previous normalization limits. New readers
accept the old object when the new field is absent; historical distinctions
already lost by an old writer cannot be reconstructed. Duplicate exact record
keys in the new format are rejected.

## Remaining identity migration

This is a read/metadata family, not complete working-file identity parity.
Native row IDs and highlighted/checked String sets, wider operation path sets,
LFS owner maps, Finder state/overlay/repository maps and restore-copy preflights
still need their connected migration. Two canonical aliases must not be claimed
fully independent in the native table selection model yet. Arbitrary invalid
UTF-8 Git paths and filesystem case/normalization aliases require separate work.
Physical/signed Finder and App Store acceptance remain open.

See [batch evidence](qa/working-file-identities-2026-10-17.json).


The grouped checkpoint passed 48 distinct relevant Core cases across the retained
run and affected repairs. The initial test-target compile needed an explicit
GitPathMap type in the existing clipboard fixture. The first executable Core run
passed 37 unaffected cases and exposed two failing new cases: Foundation URL
normalization collapsed absolute flag keys, and an invalid numstat fixture record
consumed the following row as a rename. Raw Git probes confirmed stdin preserved
both index paths under system and bundled Git. The absolute-key join and fixture
were repaired; the six identity and five amend cases passed, then those same
11 affected cases passed after the amend join migration. Unaffected cases were
not repeated. Both Debug builds passed.

Four grouped native case/engine combinations passed: Commit staging and Working
Tree footer with system and bundled Git. Commit additionally checks exact
statistics sorting and clipboard columns without putting aliases into the still
String-keyed native selection model. All four receivers were reaped and
independently absent. No new visual layout or signed Finder claim is made.
