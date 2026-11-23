# Working-status copy and rename discovery

This implementation batch connects working-status discovery to accepted action
reporting and comparison operands. The grouped checkpoint passed: 71 focused Core checks, a native app build,
and five native cohorts with both Git engines. This document does not claim
complete status-list or whole-port parity.

## Pinned behavior

The reference is TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`:

- `src/Git/Git.cpp:3459–3530`, `GetWorkingTreeChanges`, reads cached
  `diff-index --cached --raw HEAD --numstat -C -M -z` first, then whole-tree
  `diff-index --raw HEAD --numstat -C<threshold> -M<threshold> -z`.
  Cached detection uses Git's default threshold; whole-tree detection uses the
  configured threshold. It does not request `--find-copies-harder`.
- `src/Git/TGitPath.cpp:1297–1359` consumes raw R/C old-name then destination.
  Repeated destination records union their action bits and retain the first
  accepted old name, including an absent old name.
- `TGitPath.cpp:1093` and `Git.cpp:3596` add the unmerged stage fact.
  `Git.cpp:3634–3651` adds Missing to an existing row. Porcelain conflict pairs
  such as AA, AU and UA describe stage occupancy; their letters are not a raw
  Added/Deleted action union.
- `TGitPath.cpp:1782–1803`, `GetActionName`, gives caption precedence to
  Conflicted, Added, Missing, Deleted, Merged, Modified, Renamed, then Copied.

## Exact CLI ordering and observed copy boundary

Both streams preserve the pinned **`-C -M`** ordering, including configured
thresholds in the whole-tree stream. A bounded diagnostic receipt at
`docs/qa/working-status-flag-order-2026-11-23.json` records 32 real Git commands
(two engines × cached/whole × eight short/long option permutations). Apple Git
2.54.0 and bundled Git 2.55.0 emit Added with no origin for `-C -M` and
`-C50% -M50%` on an ordinary modified-source copy. Reversed `-M -C` emits C100,
but changing order would depart from the pinned source; this port retains the
source command. No `--find-copies-harder` is used. The completed diagnostic is
separate from the pending repaired grouped regressions.

The pinned parser defaults `MergeReplacedStatusKS` to true
(`TGitPath.cpp:1265`), aliases an old pathname to its destination (`:1357`), and
suppresses later A/D actions when that alias has an exact Rename action (`:1326`).
The Core projection implements that action merge and preserves the first origin.
Existing porcelain rows supply actual staging semantics; an
old-path raw update changes its accepted alias destination, not a fabricated XY.
Aliased redundant versioned old-name rows are suppressed in the report.
Controlled accepted-C protocol/operand coverage remains useful, but does not
prove natural copy discovery with the exact pinned CLI ordering.

## Accepted Core contract

`StatusEntry.index`, `worktree`, `originalPath`, `staged`, and
`hasUnversionedCopy` retain the actual porcelain facts. Detecting a copy does not
change an index Added row to an invented index Copied row. New optional
`sourceActions: SourceStatusActions?` and `sourceOriginalPath: String?` hold the
separately accepted raw projection. New optional `unversionedCopyState: FileState?` retains whether a folded local
copy was Untracked or Ignored; existing initializer calls remain valid.
Equality and hashing include these fields using the existing byte-exact path
identity contract; the earlier path equality implementation was already exact.

`reportingActions`, `reportingOriginalPath`, `isRenamed`, `isCopied`,
`actionCaption`, and nonoptional `comparisonAction: String` expose the accepted
projection to consumers. A supplied raw projection with no origin must retain
that absence rather than substitute porcelain's different pairing. Explicit
comparison action precedence is unmerged→ordinary Modified, then Added,
Deleted, Renamed, Copied, otherwise Modified. The Missing comparison-menu gate
uses the accepted Added/Renamed/Copied mask when supplied and preserves its old
porcelain fallback otherwise. Colors can use their own source mask priority;
they need not use caption priority.

`GitRepository.sourceWorkingStatus(_:base:readPolicy:cancellation:)` enriches
the accepted porcelain inventory, retaining actual destination XY while applying
the source old-name alias shape. Redundant versioned old-name rows are removed
when the cached source Rename owns that alias, including configured-threshold
porcelain D+A versus cached/default-50 R. A recreated ??/!! old path remains a
separate local-only row with its exact captured state. Legacy manually supplied
`hasUnversionedCopy=true` without that state preserves its original row rather
than guessing ignored/untracked visibility. Paths are never rewritten. A nil base pins
HEAD once; an unborn HEAD returns the original rows. An explicit revision must
be an immutable 40/64-digit lowercase object ID; an explicit empty-tree base
keeps initial Added facts, and a working-tree base is rejected. Amend callers
must enrich their final parent-relative projection against that parent, rather
than carry HEAD-relative metadata through reconstruction.

The NUL parser consumes combined raw/numstat output, including rename/copy
numstat triplets and literal tabs/newlines in names. Malformed output rejects the
projection. Unsupported invalid-UTF8 source names cannot attach metadata to a
different replacement-character name through lossy decoding. This does not add
lossless invalid-UTF8 path support to the existing String-based status API.

Automatic observation keeps `GIT_OPTIONAL_LOCKS=0` and disables diff's automatic
index refresh for supplemental reads. A global status observation adds raw reads
only when an ordinary Added/Renamed/Copied candidate can introduce pairing
metadata; clean and Modified-only observations retain their previous cheap
path. Explicit parent projections do not apply that candidate shortcut. The
cached read precedes whole-tree read and cancellation checks separate them.
`status(..., sourceReporting:false)` allows captured readers to reuse their
already accepted raw bytes; public defaults retain reporting.

Add's direct selected-file rows and the synthetic Log working-tree row use the
same enriched reader. Add keeps its default filtering and checked selection;
this change does not make tracked rows appear without the existing direct-file
selection policy. Log retains its statistics/submodule adapters and accepts raw
action/origin independently of a separately computed net patch.

## Prepared regression scope; execution pending

`SourceWorkingStatusTests` prepares real Git repositories containing a modified
source and a newly staged copy with literal Unicode/tab/newline names. Under
the exact pinned C-then-M command this row must report Added with absent origin;
actual index A is retained. Assertions compare its empty old side, exercise
actual Add/Log/captured Commit reads (including parent-relative amend), and
commit only that destination without committing or removing its modified source.
Controlled accepted-C raw/parser and existing comparison-builder cases are
explicitly separate from natural discovery. Cached Rename plus actual later
old-path Deleted output verifies default old-name alias suppression and first
origin retention; a controlled Added alias case verifies the paired rule.

A real configured-100 porcelain D+A versus cached/default-50 R witness verifies
one Rename destination, actual index A, exact origin and no redundant old D.
Folded deletion/local-copy parser cases cover both ?? and !!, both packet orders,
and the explicit unknown-state legacy boundary.

Other prepared cases cover unchanged-source non-discovery, real rename/missing,
retained `git rm --cached` copies, ignored filtering, unborn HEAD, explicit pinned
parent projection, cancellation, index bytes/mtime preservation, raw/numstat
triplets, malformed output, exact canonical-distinct names and receipt equality.
These are intended regression assertions, not reported execution results.

Remaining boundaries include end-to-end validation of both Git runtimes and
native report/menu/checkbox consumers in the grouped checkpoint. Copy discovery
follows the exact pinned CLI ordering and its observed Added result;
unchanged-source copy discovery and arbitrary malformed/combined-merge raw
protocol support are not added. Existing generic historical diff detection is
unchanged.
