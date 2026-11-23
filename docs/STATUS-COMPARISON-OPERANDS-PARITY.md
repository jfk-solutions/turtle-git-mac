# Accepted status-row comparison operands

Baseline: pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`.

Status: the scoped Core/native checkpoint passed; full port acceptance remains
open. The [checkpoint record](qa/status-comparison-operands-2026-11-23.json)
separates initial failures, focused fixture repairs and retained passing scopes.
The earlier read-only audit identified control/data-flow differences; the later
execution is bounded evidence for the implemented consumers, not installed-app,
Finder, full hosted CI or complete dialog certification.

## Connected workflow contract

Classic Commit, Working Tree and Revert accept ordered native status rows before
opening comparison windows. Paused replay recovery also supplies accepted rows,
conflict stages and its own operation context. Each row's accepted status and
literal paths must determine comparison operands; a later generic diff must not
replace that intent by detecting another rename, copy, addition or deletion.

| Accepted working-list intent | Old operand | New operand |
| --- | --- | --- |
| Initial repository / added file | Explicit empty side | Accepted working path |
| Added while amending | Explicit empty side | Accepted working path |
| Deleted | Required accepted historical path | Explicit empty side, even if that disk leaf is subsequently recreated |
| Modified or another ordinary tracked row | Required accepted historical path | Accepted working path |
| Renamed or copied | Required exact accepted original path | Accepted destination path |

The initial-repository case has no historical predecessor. Normal tracked
comparisons pin HEAD; parent-based amend comparisons pin its first parent.
Commit normalizes root-commit Amend to “Show diff to last commit”, retaining HEAD
as the effective base, as pinned `CommitDlg.cpp:1508–1513` does. The low-level
explicit empty-tree role still represents an absent predecessor without writing
a new object; it is not a claim that the root-Amend UI chooses that role. This
revision context is captured once, then each row chooses its own null/required side. A shared base alone does not
encode whether an individual side must be absent or must exist.

The accepted raw action flags retain upstream precedence: Added is considered
before Deleted, including a combined Added/Deleted row. Added uses an empty old
side regardless of amend. Deleted uses a historical old
side and an empty destination, rather than allowing a newly recreated working
file to turn the accepted deletion into Modified. An ordinary required old file
that is absent must report failure; it must not silently become Added. Exact
rename/copy origins survive competing identical sources and subsequent working
changes. Paths and canonical-distinct names retain their original Git bytes;
display normalization and a newly detected pairing are not operand authorities.

Conflicted porcelain pairs are not an Added/Deleted action union. In the pinned
implementation, raw diff-index supplies `U`; `TGitPath`'s `ParserFromLog`
(`src/Git/TGitPath.cpp:1297–1359`) maps that raw action, the stage parser at
line1093 sets UNMERGED, and `GetWorkingTreeChanges` unions that flag at
`src/Git/Git.cpp:3596`. Missing-path handling at lines3634–3651 adds only MISSING.
Thus porcelain `AA`, `AU`, `UA`, `UD` or `DU` does not make explicit comparison an
Added-null or Deleted-null operation. Explicit Compare uses an ordinary tracked
comparison for conflicted rows; primary activation still edits the conflict.
The Added-first rule above applies to an ordinary accepted Added/Deleted row,
not to inferred flags from the characters in an unmerged porcelain pair.

## Pinned source evidence

`src/Git/GitStatusListCtrl.cpp:3026–3060` copies the selected row. For Renamed or
Copied, `file2` uses `GetGitOldPathString()`. In the working-list branch, amend
adds `~1` only for non-Added rows. Initial and Added rows call `DiffNull` with
addition direction; Deleted calls it with `HEAD[~1]` and deletion direction;
ordinary rows call `Diff` with separate destination/original paths.

`src/TortoiseProc/GitDiff.cpp:100–164` constructs an actual empty temporary
operand and preserves add/delete orientation. `GitDiff.h:46` defaults ordinary
`Diff` to `mustExist=true`; `GitDiff.cpp:399–414` reports a missing required
historical file instead of silently changing the action.

The historical current-version branch at
`src/Git/GitStatusListCtrl.cpp:3062–3080` has separate parent, root, Added,
Deleted and merge behavior. This batch does not apply a blanket working-list
HEAD rule to historical Log or merge-parent comparisons. Directory/null
comparisons use the pinned submodule dialogs. `GitDiff.cpp:162` explicitly ignores
the second path in `SubmoduleDiff`; exact renamed-submodule equivalence must not
be invented from regular-file two-path behavior.

## Core and native implementation boundary

The agreed Core API is the public Sendable
`StatusListFileComparisonIntent(entry:base:isSubmodule:)` and actor method
`GitRepository.statusListFileComparison(_:cancellation:)`. The intent stores the
accepted `StatusEntry`, pinned `ComparisonRevision` and submodule classification.
Its entry retains raw action, destination and exact original path; the dedicated
one-row builder derives explicit absent or required operand roles from them.
It prepares an immutable validated comparison snapshot without rerunning
rename/copy detection. Rename/copy origins are mandatory required historical
operands. An explicitly compared conflicted row uses ordinary comparison here;
its primary conflict-editor activation remains separate. Snapshot/cache identity
must retain
those roles and literal paths. The generic `revisionFileComparison` API keeps its
independent detection behavior for its other callers.

The existing exact-path file reader already uses action-controlled absence and
the accepted old path (`Sources/TurtleGitCore/FileComparison.swift:225–261`).
Working symlinks compare their link-target text instead of following the target.
Gitlinks keep their separate pointer/null-side adapter, including index pointers
for newly added working submodules. These readers and routing rules must remain
intact while accepted status intents replace generic redetection at this handoff.

Native source models capture rows and settings before publishing busy state.
The existing `StatusListPrimaryActivationSession` and `FileListComparisonSession`
retain displayed order, one large-selection warning, cancellation, selected-row
and owner validity, backend, preferences, access lease, appearance and alternate
tool choice. Root consumes the already accepted per-row operands and checks the
same owner/token both before and after preparation. It must not warn twice,
rebind to a replacement repository or launch a stale result after source close,
selection/sort replacement, settings change, cancelled confirmation or Quit.

Explicit comparison uses the actual command routes: `Commit.compare`,
`Status.diff`, `Revert.diff` and replay's existing Compare action. Revert's own
`onCompare` path must route through
`commands.primaryFileAction(..., mode: .compareWithBase)` rather than bypass the
accepted intent builder. The generic `workingFileComparison` consumer remains
unchanged.

Classic primary activation remains Classic-only; explicit Commit Compare supports
both Classic and Git Gui-style staging. It captures the original
`activeFileMenu`, including pane, displayed order and mark. The typed operation
validates that receipt before publishing busy. Publishing its own busy state
retires GUI input receipts once; the operation records that post-busy generation
and rejects later pane generations, selection changes or changed raw staging
states before delivery. Moving between staged/unstaged panes or replacing their
rows must not revive a menu's earlier operand request.

## Retained copies and replay recovery

Default primary activation and explicit Compare remain distinct. A coalesced
Deleted row with a retained unversioned working copy can retain its existing
primary working-file preview adaptation. Explicit Compare still uses the
accepted Deleted intent with an empty new side. Unversioned/ignored file
preview, conflict editing and missing-row skipping keep their own accepted-row
dispatch; the operand builder does not turn every activation into revision diff.

Replay recovery captures its real status projection, conflict stages, session
identity, displayed selection and rebase orientation. Its native Squash
amend-to-parent adaptation is preserved where that menu supplies it; other replay
states do not automatically acquire amend behavior. Conflict editor direction,
missing-side chooser and submodule recovery remain separate from ordinary
status comparison materialization. No comparison resolves files, changes replay
checks, stages contents, commits or continues replay.

## Corrected example and validation scope

The earlier suggestion that “a file deleted by HEAD and re-added while amending
must be an Added row with an empty old side” is **not established**. Both pinned
and native amend projections compare against the parent. That row can correctly
be Modified in both implementations. See pinned `src/Git/Git.cpp:3460–3513`,
`GitStatusListCtrl.cpp:4130–4136`, and native
`Sources/TurtleGitCore/CommitAmend.swift:169–224`. It is not a verified regression
example and must not be used to claim a runtime fix.

The grouped checkpoint exercises accepted Added rows whose fresh diff pairs
another origin; Deleted rows with recreated disk leaves;
exact/raw rename and copy origins; normal/amend/initial/root contexts; required
missing historical files; symlink modes; and gitlink null/index pointers. Native
coverage carries those operands through actual Classic Commit, Working Tree,
Revert and replay handoffs with both Git engines, checking order, warning,
actual bytes, modes, paths and action roles, plus unchanged HEAD, raw index and
working files. The existing settings/cancellation ownership contracts remain
separate from the focused operand assertions.

Eight focused Core tests passed. The partially staged Added case also checks
that the independent generic comparison really detects a fresh Rename, while the
accepted-row builder retains the empty old side. The native group passed with
system and bundled Git across Commit, Working Tree, Revert, root/amend/unborn,
GUI and paused Replay cohorts, including actual old paths, null roles, source
ownership and read-only index assertions. System scopes that passed before a
fixture failure were retained rather than rerun. Fixture failures and authored
data corrections are recorded separately; no assertion was removed.

Complete TortoiseGit dialog parity, all historical merge-parent combinations, exact
renamed-submodule equivalence, physical keyboard/mouse acceptance, signed
deployment and Finder integration remain outside this document's acceptance.

Copy fidelity is also narrower than copy discovery. The current CLI status read
uses `--find-renames` and does not naturally produce copied (`C`) rows. The
native copy cohort injects accepted C metadata through the existing Commit
query seam while using real historical/tree/working-file bytes. Its pass verifies
operand fidelity and native ownership for an accepted copy; it does not establish
complete copied-row discovery in normal status collection.

## Independent consumers still to audit

This batch covers the four working-list source models named above. Add's primary
activation also consumes the shared Root plan, but its separate explicit Compare
callback still passes generic working paths. Pinned Add includes direct files
and removed-but-present rows (`AddDlg.cpp:148–153`), so untracked-only assumptions
do not close that review. Resolve, Sync and Log have independent conflict,
working-row and historical comparison routes; their accepted operands must be
checked against their actual source branch before substituting this builder.
These consumer audits remain open; this record does not certify every use of the
shared upstream status control.
