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

## Activation result and mounted-pane ownership — October 29, 2026

Header activation now returns actual focus success. A retained activation binds
the exact native pane, window, model, preferences and presentation identity;
replacing a pane cannot redirect an old action to its replacement. Hidden,
detached, unready and retired panes refuse activation. The native header keeps
its rendered enabled-state guard and reports refusal through accessibility
instead of reporting success when the model rejected the callback. Compare
refreshes mounted-pane identities independently of caret and marked-word changes;
status reads exclude hidden or foreign editors. Readonly panes remain inspectable,
with their existing mutation restrictions.

Hosted run [40801565372](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/40801565372)
on older source `adbf6be7` passed 3,222 Core methods with two skips and no
failures, then stopped at the conflict presentation check's first header press.
That fixture awaited model readiness before the native header's enabled state
had necessarily rendered. It now awaits the actual enabled header and attempts
activation once; refusal remains a failure with bounded diagnostics. This
readiness correction is distinct from the production admission-result repair.
The [dated receipt](qa/merge-header-activation-2026-10-29.json) records the
affected grouped validation and its limits.

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

## Installed acceptance corrections

Actual build 7 three-pane acceptance found three connected presentation gaps:
the Merge interface selector still occupied a large labelled left-side control;
the separate source comparison's window title exposed its private snapshot path;
and the accessible hierarchy exposed a static label without its owning header
menu. These findings supersede any inference of installed three-pane or
VoiceOver acceptance from the earlier offscreen case passes.

The authored correction gives both Classic and P4 three-pane layouts one compact,
right-aligned menu selector using the same captured AppStorage setting and
busy/Quit gates as Compare. Separate source frames now use the captured source
descriptions in the title. `MainFrm.cpp::SetWindowTitle` (3117–3154) supplies the
shortening/order policy: Mine first, Base as fallback, both only for distinct
short names. Full descriptions remain pane labels; immutable physical paths
remain locations/tooltips and identity, never replaced by descriptive metadata.
The header explicitly participates as an accessible button; its visual label is
ignored as a separate child. Show Menu, per-command custom actions and keyboard
focus retain the existing one-shot/current-owner/modal/detachment fences.

The existing native receiver now also checks the public accessibility hierarchy
contains the owning header button in Compare and P4, rather than relying solely
on direct action methods, and checks the separate frame's captured descriptive
title. The correction checkpoint and new installed/physical/VoiceOver acceptance
are pending; the earlier six native pairs do not validate these subsequent edits.

The first correction checkpoint's Compare/system case failed the new
in-process AX-tree oracle despite the header's direct native button properties;
a containment retry failed the same oracle. Both attempts remain recorded. An
isolated public AppKit/SwiftUI control showed that the in-process hosting-view
children also omit a standard SwiftUI Button, while the actual system AX server
exposes both that control and the explicitly accessible native header button and
its named actions. `finishLaunching` is required for the receiver's system AX
server; querying the in-process hosting-view tree is not equivalent.

The unnecessary containment change was removed. The fixture now queries only
its own process through public `AXUIElement` APIs, without requesting permission,
and requires an existing standard Save button as a control before asserting the
header's exact description/help, button role, Show Menu and complete named
action set. Existing direct retained-action dispatch still checks one-shot and
owner/detachment fences; this does not claim a separate external assistive
client dispatched those actions. The affected grouped checkpoint remains pending.

The first true-system-AX Compare/system case passed. The following Merge/system
case found that accepted document loading still overwrote the previously
configured source frame title with the private snapshot path. The repair now
uses one computed title policy in initial controller creation, metadata setup
and every accepted load, including reload and side swaps. Captured descriptions
follow physical input identity when panes exchange; ordinary and image titles
retain their previous path/IDiff policy. The existing source-child scenario now
checks reload plus a round-trip side swap and original input bytes. This focused
repair's checkpoint remains pending; earlier title assertions are not a pass.

### Final local correction checkpoint

The [correction receipt](qa/merge-pane-acceptance-corrections-2026-10-25.json)
records the final grouped six scenario/engine pairs passing after the preserved
AX-oracle and real load-title repairs. System and bundled Git pass Compare, Merge
and ownership scenarios; all six receivers are independently absent. The actual
self-process macOS AX tree exposes the button, Show Menu and named actions, with
a standard Save button as a control. Direct guarded action dispatch remains
separate from an external assistive-client interaction claim. Installed build 7
predates these source corrections; signed/physical VoiceOver and full-dialog
acceptance remain open.
