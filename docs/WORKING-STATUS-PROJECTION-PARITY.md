# Working copy/rename status projection

The grouped Core/native checkpoint passed. This describes one connected
reporting and mutation-policy family, not full port completion.
Reference: pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.

## Source contract

`Git.cpp:GetWorkingTreeChanges` at 3460 and its commands at 3507–3532 use cached
and whole-working `diff-index --raw --numstat -C -M` passes, combining actions by
literal destination. Copy detection is not equivalent to porcelain status's
`--find-renames`. Crucially, the exact pinned order is **-C then -M**: the
subsequent rename option disables copy detection in the measured system and
bundled Git matrix. A copied old-source destination alongside a modified source
therefore reports **Added with no origin**. This port retains that exact order;
it does not substitute -M -C merely to obtain working Copied rows. Historical or
controlled accepted C metadata still has a separate presentation/operand contract.
This batch adds source metadata flow; it does not claim an existing equality bug
or a naturally reported working C that the pinned command does not produce.

The cached pass uses upstream's default 50% similarity, before the whole-tree
pass at the configured threshold. Duplicate destinations union action flags but
retain the first origin, including an absent origin. Neither a later pairing nor
porcelain's original name replaces that accepted source operand. Ordinary status
observers add the source reads only for tracked Added/Renamed/Copied candidates.
Commit's captured display read reuses its three existing raw+numstat streams,
with the source's cached/unstaged default thresholds and configured whole-tree
threshold. Reporting adds no scan at either default or custom thresholds.
Parent-amend reads apply the same rules to the pinned parent.
These reads disable optional index writes and honor cancellation; they are
accepted display data, not a substitute for fresh commit mutation preflight.

`TGitPath.cpp:GetActionName` at 1782–1815 chooses the caption in order: Unmerged,
Added, Missing, Deleted, Merged, Modified, Renamed, Copied, then index flags and
fallback. The caption is not always Copied merely because a union contains C.
`GitStatusListCtrl.cpp:3427–3440` chooses text color separately: Conflict,
Modified, Added/Copy, Deleted, Renamed, Merged. Copy shares the Added role, with
existing source-derived status artwork and native light/dark palette handling.

## Native behavior

Core supplies additive `sourceActions`/`sourceOriginalPath` metadata and shared
`reportingActions`, `reportingOriginalPath`, `actionCaption`, `isRenamed`,
`isCopied`, and `comparisonAction` accessors. Actual porcelain index/worktree XY,
porcelain originalPath and staging membership remain independent. Equality and
hashing now include the additive metadata, preserving its identity in accepted
menu/report/comparison receipts as it begins to exist.

Classic Commit, Working Tree, directly selected tracked files in Add, Log's
working row, and the workspace consume these shared captions/origins. They no
longer infer all origins as Rename or gate Copy's old-name history on an absent
porcelain R/C letter. Copy tooltips say “Copied from”; user paths are never
localized. Historical Log `CommitFile` rows retain their historical action model
and likewise distinguish their own Copy origin. Log historical comparisons and
revision endpoints are unchanged.

GUI staging keeps its partially-staged label and otherwise uses the shared action
caption, so its status meaning agrees with the accepted report. Classic checkboxes still
select independent paths. Showing a Copy origin does not select/check/stage that
origin or remove it as a Rename source. Add keeps its upstream default untracked
filter; tracked copy/source rows appear only when explicitly selected as files.
No new default columns are introduced in Add: its tooltip, clipboard and old-name
menu retain the reporting metadata.

## Mutation and accepted operands

The source CommitDlg 1100–1310 uses the raw Renamed action to remove/reset an old
name, Added for unchecked remove/readd, and Deleted for checked removal. Missing
alone does not become a deletion restoration. The corresponding Core selection,
checkbox-index and amend consumers use source action predicates. A copied row's
historical origin is a comparison operand, not a path to remove. Amend projection
is enriched against its pinned parent and preserves raw staging values.

The dedicated working-list comparison builder retains the accepted source old
path/action; Copy preparation must not silently become Added or Rename through a
second detection pass. Existing cancellation/settings/backend/window/document
ownership guards continue to cover the enriched receipts. Unified, historical,
conflict-stage and literal two-file meanings remain their separate workflows.

Revert now uses raw source Added/Renamed flags for its independent recovery-copy
policy and operation branch, and expands only a real Renamed reporting origin
into counterpart paths. Copy origins never become rename removals or unrelated
Revert targets. Existing private-index transaction, Trash recovery, error,
cancellation and ownership semantics remain in place. A controlled C-only policy
may recycle and then fail historical checkout if HEAD lacks the destination;
that is not misreported as successful deletion. The actual pinned natural-copy
witness is Added and retains Added-only Revert behavior. Blame menu masks use
source Added/Deleted flags, while historical attribution still uses HEAD and
preserves honest missing-path errors rather than inventing working attribution.

## Checkpoint and limits

`docs/qa/working-status-projection-native-2026-11-23.swift` with
`scripts/test-working-status-projection.py` is the bounded native cohort. Its
selectors are `commit`, `status`, `add`, `log`, and `revert`; default runs all with both Git
engines through the cached receiver. The fixture authors copied bytes alongside a real modified source plus an
independent rename and uses actual status reads; it never injects C. It asserts
the copied destination is Added/no origin on both engines, has no invented Copy
old-name menu, and compares with an empty old side. Whole-repository Commit, Status and Log reads retain the real Rename
accepted old path and old-name action. Direct-file Add reads query each literal
scope independently, so that same destination is Added with a null old side;
including the old path as a separate scope does not pair it. The Add fixture
checks that bounded behavior explicitly. Mounted reports check shared captions,
color/icon roles, clipboard preparation/private pasteboards and actual Root
comparison operands. The Commit cohort also stages/unstages the
copy destination and commits only that checked destination while asserting the
independent source's HEAD and working contents survive; its unchecked ordinary
Modified index row resets to HEAD, as CommitDlg and the existing checkbox-policy
Core cases require. Stage/unstage of the destination still preserves the source
index exactly before that explicit Commit policy runs. The Revert cohort
accepts actual Added/Rename rows through the native dialog and real progress
controller, retains Added working bytes, restores the Rename old path, and keeps
the independently modified source out of the operation. A focused controlled
Core policy case covers Copy versus Rename recycling without claiming natural C.

All repositories, preferences, helpers and windows are private; automated owners
and sheets remain invisible and drain before completion. Validation results must
be recorded separately after execution. This document does not establish hosted
CI, physical Finder acceptance, signed deployment, every dialog's visual parity,
all copy heuristics, arbitrary ambiguous-copy choices, or complete historical
status-list parity. Git's detected source may be ambiguous; the accepted raw
source identity is retained rather than asserting an invented universal choice.

The [recorded checkpoint](qa/working-status-projection-2026-11-23.json) separates
the initial source-assumption failures from the focused repairs. It records 71
passing Core checks, ten native cohort/Git passes, the app build and 45 CI
admission checks. No full hosted pass, signed deployment, physical Finder check
or complete visual/source parity is claimed. The later [scoped status checkpoint](qa/scoped-working-reads-2026-11-23.json)
records bounded Add/Revert reads. Its read scope is retained by the current
implementation; the older whole-repository Add Rename expectation was obsolete.

## Scoped fixture alignment — November 23, 2026

The [alignment checkpoint](qa/status-report-fixture-alignment-2026-11-23.json)
records eleven focused clipboard Core methods and sixteen native cohort/engine
passes cumulatively. The clipboard action follows its accepted row independently
of statistics. Add uses per-file Added/null-side semantics; whole-repository
Rename oracles remain intact. Working Tree pointer routing assertions now report
the exact action, path, Shift and selection component. Initial failed assumptions
and the source-based correction remain in the receipt. Only affected Add groups
were repeated; the passing Core and legacy primary checks were retained.

No production code changed in this alignment. Cached app/Core source equality
was checked; no app rebuild or broader validation was substituted for that scope.
Full hosted, physical/signed and owner acceptance remain separate.
