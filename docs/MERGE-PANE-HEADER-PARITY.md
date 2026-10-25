# Compare and Merge pane-header workflows

Pinned TortoiseGit source: `7338078f8ddd924b8cddee35f512f2286072136d`.
This is a connected continuation of [pane identity and status](MERGE-PANE-PRESENTATION-PARITY.md),
not certification of the complete editor.

## Source behavior

`TortoiseMerge/BaseView.cpp::OnContextMenu` (2398–2453) treats the filename
header separately from the editor text. With the bottom/result view visible,
the left and right headers offer **Show diff separately**
(`IDS_HEADER_DIFFLEFTTOBASE` / `IDS_HEADER_DIFFRIGHTTOBASE`,
`Resources/TortoiseMergeENG.rc` 1200–1201). The bottom header offers Explore To
with `IDI_EXPLORER`.

`MainFrm.cpp::DiffLeftToBase`, `DiffRightToBase` and `DiffTwo` (1286–1315)
launch a separate comparison of the original Base and Theirs/Mine files, in that
order, preserving their descriptive window names. It is not a comparison of the
edited result with the clicked source. The source Save As and input-rebinding
semantics remain those described in [source-pane tools](MERGE-SOURCE-TOOLS-PARITY.md)
and [Save workflows](MERGE-SAVE-WORKFLOWS-PARITY.md).

## Native implementation and adaptations

The classic native header now has a real AppKit context menu. Source headers
expose **Show diff separately** through the existing independent comparison
workflow. That workflow uses the accepted original Base and selected source
bytes, including a source's accepted Save As target, not the mutable result or
alignment display text. It carries descriptive pane titles independently from
the private snapshot filenames. The independent child owns its read-only
snapshots until the child closes and its reads drain; closing the parent does not
silently invalidate an independent comparison.

The native snapshot adaptation deliberately compares the accepted document's
source version. Upstream launches another process against live filenames. Keeping
an externally changed input retains its older accepted version in the native
editor until Reload or a separately accepted Save As; this command does not
silently bypass that choice by rereading outside the document's existing grants.

**Reveal in Finder** is the macOS adaptation of Explore To. It uses a captured
actual live input, rebound Save As target, or known existing merged output.
Reflected/descriptive labels, historical object names and private immutable
comparison snapshots are not filesystem destinations. An unnamed result has no
Reveal command until an output has been accepted. A repository result-copy Save
As retains its established copy-versus-normal-save semantics; it does not
silently change the original result target just to reveal the copy.

The connected native header menus also reuse existing **Save this pane as…** /
**Save merged result as…** actions. These additions are native conveniences,
not claims that upstream exposes those commands in every header. Two-pane and
combined Compare use the same existing saved-target writer. Optional Base preview
exposes only a known live-file Reveal, without inventing Base editing or a
Base-versus-result comparison. The compact P4-style headers reuse the same
captured command availability and dispatch, without changing their filename,
source-choice buttons or layout.

Classic headers retain left-click and accessibility-press pane focus. Their
context menu is available by right-click, Shift-F10 while the header has keyboard
focus, and the accessibility Show Menu action; individual custom accessibility
actions use the same command receipts. Original Compare/Save As/Explorer artwork
respects the owning context-menu icon preference. The P4-style filename field uses the same native header menu adapter in a
compact presentation. Reopening it creates a fresh invocation even after Reveal,
which does not publish a model change. Physical keyboard and VoiceOver acceptance
still require separate review.

Each captured command binds its exact model, window, pane role, generation,
source layout/result presentation, current attached native pane, preference epoch
and raw target-path bytes.
Busy work, sheets, an application-modal window, Quit, retirement, pane exchange,
new output adoption and File/Open replacement refuse stale dispatch. Native menu
and accessibility invocations are consumed once; fetching a fresh menu/action
creates a fresh receipt. A nil-window interval invalidates old native header
commands even when the same view later reattaches. A coalesced attached-pane
identity notification refreshes header receipts after readonly source or optional
Base mounting, even when focus, column and mark counts do not change; attaching
or detaching a view schedules that update without reloading or changing selection.
Save As retains the existing
owned panel, cancellation, grant, guarded-write and late-answer fences. No new
Git operation, repository adoption or permission bypass is introduced.

Implementation: `MergePanePresentation.swift`, `FileComparisonWindow.swift`,
`TextConflictWindow.swift` and `MergeSourceComparisonWindows.swift`.

## Verification and remaining scope

The new receiver `qa/merge-pane-header-native-2026-10-25.swift` and cached runner
`scripts/test-merge-pane-header.py` author three grouped scenarios: Compare saved
paths/Save As/combined replacement, source/result Merge comparison and exports,
and menu/accessibility/detach/owner cancellation. They use private repositories,
preferences and offscreen windows, and retain HEAD/index/input-byte witnesses.
The affected Debug build and six cumulative native case/engine pairs pass;
[the dated record](qa/merge-pane-header-2026-10-25.json) retains the initial failures,
startup/mount repairs, fixture settlement fixes and exact validation scope. The
initial system Compare pass was retained rather than repeated after Merge-only
repairs. Two original two-pane Compare captures were reviewed in light and dark
appearances; they do not establish three-pane Merge visual parity. No Core
implementation changed in this family.

Physical context-menu/keyboard/VoiceOver use, every P4-style accessibility route,
all file-provider/sandbox grants, minimum-version/Intel behavior, signed installed
acceptance and full hosted CI remain separate acceptance work. Complete source
menu/layout equivalence and all editor workflows are not established by this
family.
