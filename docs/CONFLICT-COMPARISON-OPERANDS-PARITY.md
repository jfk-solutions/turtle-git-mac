# Resolve working comparison operands

The grouped native checkpoint passed. This is a bounded workflow
family, not completion of Resolve, Sync, every dialog, or the whole port.

The reference is pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.

## Source behavior and the native correction

`ResolveDlg.cpp:60` enables the shared status-list compare commands. The
`GitStatusListCtrl.cpp:2234–2244` Compare command checks `NumDiffWarning` once,
then walks selected report rows in order through `StartDiff`.
`StartDiff` at `3037–3065` uses accepted status/old-path information and
HEAD versus the working file (or the explicit empty side for Added/Deleted),
rather than the unmerged index's stage-1 ancestor. Porcelain conflict occupancy
letters such as AA/UD are not upstream raw Added/Deleted action bits.

The native Resolve working-list Compare previously opened a stage-1 comparison
for one ordinary conflict, or an aggregate `diff --base` for multiple conflicts.
Its configured `onWorkingFileComparison` now sends accepted ordered rows to the
same Root/Core `StatusListFileComparisonIntent` path as other working reports.
HEAD is resolved before the one multiple-comparison question. Initial repositories
retain the shared empty-base intent. The stage-1 document remains available through
`viewConflictBase`; the unconfigured `compare` API keeps its ancestor-viewer
fallback for existing standalone consumers. Edit Conflict and the literal
Compare Two Files command retain their separate meanings.

The unified command has a different source contract. `GitStatusListCtrl.cpp:
2285–2308` calls `GetUnifiedDiff` for each selected report path and appends the
patch bytes into one viewer; it does not call `CheckMultipleDiffs`.
`Git.cpp:3090–3118` builds `diff --stat -p HEAD -- path` for working operands.
The native command now pins HEAD, preserves report order, uses the captured diff
backend and emits one aggregate of raw patch bytes. It compares the live working
file with HEAD, not stage 1. It deliberately does **not** substitute a two-pane
snapshot's Added/Deleted null-side policy. A recreated working leaf belongs in
these unified bytes. The model's standalone unified presenter follows the same
HEAD/working contract and retains captured Shift/tool invocation. Unified refuses
an initial repository without HEAD, as the source HEAD-naming command does; it
does not manufacture an empty historical revision for this separate command.

## Accepted state and lifetime

Resolve captures the exact displayed `ConflictEntry` stage IDs/modes, source
selection, report sort, model/window generation, rebase orientation, preferences,
backend and alternate-tool intent synchronously. A selected-only literal-pathspec
porcelain read supplies real raw status rows without rescanning the repository or
writing the optional index-stat cache. Actual stages are validated before and
after that read, and orientation is rechecked before the question.

The shared selection session owns the cancellable request and its single Compare
question. Root revalidates accepted stages and orientation around preparation and
before presentation. Unified uses the same cancellation/owner receipt with no
many-diff prompt and revalidates around its per-path patch reads. A stale Yes,
changed selection, settings/backend replacement, changed stages/orientation,
Cancel, source close or Quit cannot admit a late child. Existing Resolve active
operation and controller-release counters retain Quit ownership until suspended
work and paired sheets drain. Queued refresh remains owned by the existing
`finish` path. No new Git mutation or external execution policy is introduced.

## Sync boundaries retained

`SyncDlg.cpp:1068–1070` gives the conflict list Explore/Open/Log/Conflict/Resolve
commands; it does not expose working-list Compare. The current native Sync
conflict mask agrees, so this batch adds no unsupported command or callback.
Its managed Resolve child receives the corrected actual Root configuration.

The incoming/outgoing masks at `SyncDlg.cpp:1053–1055` and their counterparts
select `COMPARETWOREVISIONS`/`GNUDIFF2REVISIONS`. The shared handlers call
`StartDiffTwo`, preserving the explicitly installed historical endpoints. Native
`SynchronizationFileListState.compare` already retains its immutable child
snapshot endpoints, action and old-path information; substituting a HEAD working
comparison here would change the source meaning. Those historical paths remain
unchanged.

## Verification scope and remaining limits

New native cohort: `docs/qa/conflict-comparison-operands-native-2026-11-23.swift`,
run by `scripts/test-conflict-comparison-operands.py`. It uses actual mounted
Resolve reports/context-menu actions and actual Root configuration, private
repositories/defaults, invisible windows, injected final presentation and exact
HEAD/index/working-byte preservation. Its bounded selectors are `working`,
`unborn`, `retirement` and `sync`; default runs all with system and bundled Git.

The implemented assertions cover one actual native Yes/paired-sheet drain,
ordered HEAD/empty comparisons, distinct HEAD and stage-1 bytes, separate ancestor
and two-file APIs, actual aggregate unified bytes/Shift/no-many-prompt, stale stage
and orientation replies, selection/tool/backend cancellation, source cancellation,
Quit ownership, raw-read orientation replacement and forced close waiting for an
actual suspended scoped-status read. The existing retained Resolve file-menu
stage-1 materialization assertion remains unchanged for its unconfigured fallback.

No new executable gate has been added to suspend Root's internal Core snapshot or
patch read: the exact post-read stage/orientation checks are source-reviewed;
the fixture proves held-question and scoped raw-read replacement, and does not
claim that it physically interrupted each low-level Core read. This cohort does
not establish signed deployment, Finder acceptance, visual parity of every
Resolve/Sync state, or every historical/directory/submodule comparison case.

## Grouped checkpoint

The app build and this family's native cohorts passed with system and bundled
Git. The [combined record](qa/remaining-comparison-consumers-2026-11-23.json)
retains failed attempts, focused fixture/compile repairs, passed scopes and
cleanup evidence. Core source did not change, so its previous focused pass was
not repeated. Local native checks do not establish complete hosted, signed,
physical or whole-dialog parity.
