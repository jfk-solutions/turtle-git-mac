# Conflicted Commit selection and index preparation

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
Implementation baseline: `0643fbcd`. This related Commit family passed its scoped
grouped checkpoint after the recorded compiler, fixture and staged-mode repairs.

## Source contract

`GitStatusListCtrl::CheckEntry`, `SetEntryCheck` and `GitStageEntry` distinguish
checkbox selection from staging state. When automatic checkbox selection is
enabled, its source mask includes conflicted files, including direct-file scopes.
With that preference off, explicit row/highlight/group/bulk choices can select
them. Live unmerged entries start unstaged in staging mode. Checking or staging
a conflict can add its current working content and resolve the index stages.
It must not silently skip that file or replace a Stage action with Unstage merely
because an unmerged index entry exists.

`CommitDlg::PrepareIndexForCommitWithoutStagingSupport` prepares checked current
content and resets unchecked tracked rows to the comparison tree. The dialog's
ordinary checkbox policy therefore also applies to unchecked conflicts after an
explicit Ignore decision. Working files are not rolled back by that index
preparation. Added/deleted/missing and renamed cases retain the source engine's
classification and restoration rules rather than treating all conflicts alike.

Staging support commits the actual prepared index; it does not acquire checkbox
whole-file preparation. An unresolved index can still make Git reject a commit.
Source command 3 selects checkbox index preparation independently of command 10
for the separate Add command. Manual Commit-row staging follows the pinned
`GitStageEntry` CLI path; it does not inherit either command-mask choice. The
originating preference context must survive accepted
attempts and asynchronous warning/progress work.

## Native and Core scope

The batch covers explicit row/highlight/group/bulk selection, staging current
conflicted content, comparison-base handling of unchecked conflicts, both CLI and
libgit2 index preparation, selected modes, clean filtering and real-index
publication. Prepared object metadata must not trigger another clean filter merely
to reconcile the real index. Existing resolve-undo data and unrelated index state
must retain their Git semantics; concurrent index replacement must not be silently
overwritten.
The [Git index-info protocol](https://git-scm.com/docs/git-update-index#_using_index_info)
provides metadata updates without rereading working content. Git documents
[resolve-undo entries](https://git-scm.com/docs/git-ls-files#Documentation/git-ls-files.txt---resolve-undo)
as the data used to recreate an accidentally resolved conflict; publication must
not discard them merely to copy a prepared stage-0 object.

The unresolved OK/Ignore question and merge information hint have separate source
suppression keys (`CommitWarnOnUnresolved` and `CommitMergeHint`). Their native
questions must remain owned, one-use and cancellable; late replies cannot advance
retired work. Saved Data clearing and the original preference domain remain
consumers of those choices.

CLI preparation retains the source order: Add, forced removals, tracked updates,
checked rename-source removal, unchecked added-entry removal, then tracked resets.
Successful earlier command groups remain observable when a later group fails or
is cancelled. Libgit2 instead retains its source single prepared-index write.
Post-progress restoration does not run before Git progress has been attempted.
Hook rejection, cancellation, missing files and publication/restoration failures
retain their actual index effects. A completed commit is not rolled back or
reported as an unattempted operation. Literal path handling, private indexes,
permissions and process drainage remain part of the workflow.

## Verification boundary

Forty-four distinct relevant Core methods passed across the initial grouped run
and the ten affected repair cases. Eight native case/engine pairs passed:
selection, warnings, staging and ownership with system and packaged Git. All
eight receivers were reaped and independently confirmed absent. The native cases
used the built app objects before the final explicit-mode-only Core repair;
that repair skips paths without mode overrides and did not affect these cases.
Four complete offscreen light/dark captures were reviewed. The final Debug command
exited zero with current native objects and a fresh Core framework, but retained
a contradictory SwiftCompile failed-with-exit0 diagnostic; this is not a clean
hosted build claim. The build logs and
[dated evidence](qa/commit-conflicted-selection-2026-10-21.json) record the actual
checkpoint and failures. Source text, a model existing or a narrow passing case does not
certify the complete Commit dialog, physical input/accessibility, external filter
and hook combinations, signed Finder grants, hosted CI or App Store distribution.

[Checkbox selection, light](site/assets/commit-conflicted-selection-light.png) /
[dark](site/assets/commit-conflicted-selection-dark.png), and
[staging, light](site/assets/commit-conflicted-staging-light.png) /
[dark](site/assets/commit-conflicted-staging-dark.png) show the actual native windows.

## Retained rename rows and fresh conflict state — October 21, 2026

The hosted 62330c51 run exposed three failed assertions in two existing
CommitPatch methods: whole-file Unstage could leave a captured rename source
staged after Git chose a different identical source, and Stage after Unstage
could add only the new name. Fresh status classification added for conflicts
must not discard the source row's retained rename path. Copies remain distinct:
their old path is not a rename deletion and must not acquire whole-file changes.

This connected repair covers retained and fresh rename identities, ambiguous
pairing, repeated Stage/Unstage, copies, comparison-base amendment and unborn
repositories, current conflicts and literal-path validation before mutation.
Pinned GitStatusListCtrl.cpp948–983 (GitUnstageEntry) retains the selected entry's old rename path in
its second reset command; GitStageEntry adds the selected current path. The
native whole-file two-path adaptation must retain its selected identity while
consulting current conflict state. Index/tree membership includes directory
ancestors once, avoiding a scan of the complete index for each selected row.
Already-absent sides are safe no-ops, and ignored copy-source metadata is not
validated as an operand.

The [dated checkpoint](qa/commit-retained-staging-2026-10-21.json) records 21 Core
methods passing, including both previously failing hosted methods, plus four
native case/engine pairs for real retained rename/copy/ambiguous staging and
owned cancellation. Initial fixture compilation and initialization errors are
retained in the record; no assertions were removed. The Debug build passes.
Native UI controls/layout are unchanged, so the prior captures remain applicable
within their original limits. All five receiver processes are absent. Full current
hosted CI, physical input/accessibility and signed Finder acceptance remain open.
