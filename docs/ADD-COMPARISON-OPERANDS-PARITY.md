# Add: explicit comparison operands

Baseline: pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`.

Status: the grouped native checkpoint passed with both Git engines. The prior
accepted-status checkpoint did not establish this Add menu path; this family
now checks the actual menu that previously called a generic path-only callback.

## Source behavior and reachable rows

`src/TortoiseProc/AddDlg.cpp:148–153` combines `SHOWUNVERSIONED`,
`SHOWDIRECTFILES` and `SHOWREMOVEDANDPRESENT`, optionally `SHOWIGNORED`.
Add therefore has a broader report than recursively discovered unversioned
files: explicitly selected tracked files and retained disk copies after index
removal can also appear. Native `GitRepository.addDialogSelection` retains those
categories and accepts existing direct-file metadata. Missing files that have
no disk leaf are excluded by that existing selection implementation; this
batch does not fabricate an ordinary absent Deleted row in Add.

`src/Git/GitStatusListCtrl.cpp:1739–1750` enables base comparison using the marked
row's action masks. The command at lines2234–2247 iterates every selected row
and calls `StartDiff`. It differs from Return at lines3618–3655: Return edits
conflicts or previews unversioned/retained current files, while explicit Compare
uses `StartDiff` for those selected entries when the marked row permits it.
A removed-and-present row alone does not enable Compare. A marked ordinary
tracked row can enable the command for a mixed selection containing such a row.
The highlighted set, checkbox set and mark have separate roles.

`StartDiff` at lines3026–3060 copies the accepted row, keeps the exact old name
for Rename/Copy, gives Added precedence over Deleted and chooses null old/new
operands for addition/deletion. An explicit conflict comparison follows its
ordinary historical-to-working path; it does not use the default conflict editor
or silently choose stage1. Porcelain conflict letters describe stages rather
than an Added/Deleted union, as explained in
[the shared operands contract](STATUS-COMPARISON-OPERANDS-PARITY.md).

## Native implementation

`AddFileTable.Coordinator` routes the actual captured **Compare with base** menu
to `AddWindowModel.compareFileActions`, retaining the existing source icon,
marked-row eligibility, current rendered projection, sort order and one-use
menu-generation guard. The ordered selected `AddDialogEntry` snapshots retain
raw status, original path and retained-copy flags. The native header, columns,
checkboxes, row selection, mark and persistence are not replaced by another
report implementation.

The model enters the existing owned `StatusListPrimaryActivationSession` with
`mode: .compareWithBase`. This explicitly differs from the unchanged primary
Return/double-click mode. All selected rows are included in the one multi-file
warning and delivered in native display order. Shift, backend, tool preferences,
source window and access lifetime are captured before asynchronous preparation.
The accepted generation/records/selection and setting receipts remain current
through the warning and child handoff; stale selections, replacement projections,
settings changes, Quit or retired sources refuse delivery.

Production Root already supplies `onPrimaryFileActivation`; it presents the
accepted rows through `showStatusListPrimaryFiles` and
`statusListFileComparison`. Thus a retained Deleted row in explicit Compare
keeps its historical old operand and explicit empty destination, even when its
physical disk leaf exists. The same row's primary activation continues to preview
the current disk file on both sides. Renames retain their accepted literal old
name, additions retain an empty old side, ordinary/conflict comparison uses the
captured HEAD base, and a missing required old operand refuses rather than being
reclassified by a fresh whole-tree diff.

Cancel/Close retains the source operation counter until the actual owned launch
returns. Native warning Yes/No/Cancel waits for both AppKit sheet links to detach
before a child is delivered or the source's close completion is released.
Refresh requested during an accepted launch is deferred until that launch drains.
The existing application Quit guard observes the same Add operation lease.
Independent consumers that do not install the typed callback retain the legacy
`onCompare(paths)` fallback; that compatibility callback does not itself prove
accepted-operand behavior in an independently supplied implementation.

## Dedicated grouped receiver

`docs/qa/add-comparison-operands-native-2026-11-23.swift` mounts the actual native
Add table, selects real rows and invokes its real captured menu item. The
receiver uses private repositories/preferences, alpha-zero offscreen windows,
injected child presentations and explicit success/failure cleanup. The external
application is never launched as an application-main test instance.

`scripts/test-add-comparison-operands.py` reuses native receiver compilation
caches, defaults to the complete family with system and bundled Git, and records
JSON plus compact per-engine logs in `build/qa`. Repeated `--only` selectors
permit a focused repair to recheck only affected cohorts:

| Cohort | Prepared assertions |
| --- | --- |
| `operands` | Natural direct A/R/U/M and retained D metadata; reverse native order; one held warning; exact old name and null sides through actual Root; moved HEAD and changed destination disk after admission; original index/disk preservation; checks/selection/mark/header identity |
| `primary` | Real Return keeps default conflict-edit/current-file/ordinary split, ordered Root dispatch, one warning and Shift; retained/untracked/ignored previews use working-to-working |
| `stale` | Mark-dependent eligibility; retained menu selection replacement; selection/tool/backend/projection/Quit changes while warning is held; declined warning; one-use captured menu |
| `ownership` | Held accepted launch owns source and Quit counters; refresh deferred exactly once; forced close cancels and waits for actual launch acknowledgement, with no late Root delivery |
| `native-warning` | Real native Yes and source-close Cancel; both sheet links detached before handoff; cancelled source closes without a viewer |
| `legacy` | Ordered independent path-only fallback and unchanged singleton conflict/preview/check behavior |

The authored rows use actual Git status/stage metadata. No natural copied-row
claim is made; exact C operand behavior is covered by the separate controlled
accepted-row cohort in the earlier shared operands checkpoint. This fixture
checks the current Add direct-file projection, not a claim that a files-only
Finder Add invocation opens a dialog: the existing files-only route stages
immediately, while the dialog route admits folder/mixed selections.

Remaining scope includes physical Finder and accessibility acceptance, complete
hosted CI, all historical/merge-parent consumers, and complete directory/gitlink
Add-dialog comparison parity. Source review and scoped native passes do not certify
the full port or replace the coordinated batch checkpoint.

## Grouped checkpoint

The app build and this family's native cohorts passed with system and bundled
Git. The [combined record](qa/remaining-comparison-consumers-2026-11-23.json)
retains failed attempts, focused fixture/compile repairs, passed scopes and
cleanup evidence. Core source did not change, so its previous focused pass was
not repeated. Local native checks do not establish complete hosted, signed,
physical or whole-dialog parity.
