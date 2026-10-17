# TurtleGitMerge Open

Source: pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`OpenDlg.cpp/.h`, `IDD_OPENDLG`, `MainFrm.cpp::OnFileOpen`.

Tools → Open in TurtleGitMerge opens a native dialog with Merging / Apply unified
diff radios, separate visible groups, Base file / Their file / My file,
Diff file / Directory, Browse buttons, clipboard checkbox and OK / Cancel / Help.
The last successful mode is saved; Cancel leaves it unchanged. Inactive fields
are ignored. Selecting clipboard disables Diff file; bytes are captured at OK.
Private TurtleGit/TortoiseGit unified-diff UTIs and explicit copied patch text
are supported. Patch preparation remains immutable and uses the existing native
review/apply tool, including its target chooser if Directory is empty.

One input opens the right-hand text pane; two inputs open comparison in source
order. Base+Their with no My uses Their as My; Their+My with no Base uses Their
as Base. Three inputs open the existing three-pane text editor with a standalone
Subversion-backed merge. No Git repository is created and no index operation
runs. The result starts unnamed; Save opens the native Save As panel. My supplies
initial output encoding/permissions. All input files stay unchanged unless the
user explicitly selects one as output. Save validates all input snapshots and
the chosen output snapshot, supports backup/empty-delete/recreation, and refuses
external changes. Mark as resolved is disabled for standalone files. An initial
merged result differing from My is dirty and participates in Close/Quit prompts.

Browse owns native file/directory panels and retained security-scope leases.
Typed paths in App Store mode require explicit Browse authorization. Closing a
picker's owner fences late replies. Standalone editors retain all file grants
for load/save; the app's ordinary repository context remains unchanged.

The app build and grouped native Merge receiver passed. Seventeen backend
cases passed initially; the remaining directory URL assertion passed after its
focused fixture correction. The Save As correction passed two additional
backend cases and the focused native Open receiver; its first-save/cancel and
input preservation checks passed. See the [dated QA record](qa/merge-open-2026-10-12.json).
Shared input paths are supported. Explicitly saving to an input updates its
snapshot for subsequent Save/Save As, empty deletion/recreation and Reload.
Atomic hard-link replacement keeps untouched linked inputs at their old baseline. Path fields accept file URL drops with file/directory gates and retained grants.
Native filesystem completion preserves tilde paths, limits suggestions and avoids
enumerating unauthorized folders in App Store mode. A dialog-owned clipboard
monitor checks format metadata and change count without reading clipboard bytes;
it stops on close. Owner closure cancels the picker and fences late responses.

Physical picker/drop/path-autocompletion acceptance, full light/dark captures, source File/Open replacement of an existing
editor rather than a separate window, exact single-pane toolbar pruning and
signed App Store acceptance remain pending. The directory patch-review list is
implemented by the existing patch workflow and still has its own parity gaps.

The [upstream Open manual](https://tortoisegit.org/docs/tortoisegitmerge/tmerge-dug-open.html)
confirms the unnamed three-file output. First Save and Save As Cancel leave
inputs/output routing unchanged; later Save reuses the selected output.

The lifecycle follow-up passed all 11 Open backend cases and four targeted
snapshot checks after refinement. Its final native receiver passed dropped
URLs, completion, actual metadata timer/owner closure and repeated output-to-input
saves. A format can be added without changing macOS pasteboard ownership count,
so monitoring checks both count and advertised formats, never contents. See the
[lifecycle QA record](qa/merge-open-lifecycle-2026-10-12.json) for failures, repairs
and exact scope. Case-insensitive pathname variants still need volume acceptance.


## File/Open replacement batch — partial native parity

Native comparison windows now share a window subclass so two/three-pane
controllers can replace content while retaining the same NSWindow and geometry.
An owned Open workflow spans the Save/Don’t Save/Cancel question and Open sheet;
repeated commands are fenced, failed Save prevents replacement, and owner close
retires children/late replies. Replacement constructs the next input snapshot
before retiring the prior editor, transfers window/delegate/keyboard ownership
and retains only the current replacement controller in the original registry
owner. New input leases travel with the receiving editor.

The native File/Open replacement implementation is built and verified within the following scope. Scoped File/Open and Reload entries now follow the active editor; Command-O
and F5 route through that owner. Close/Quit refuse the question/Open interval,
and independent Save accounting survives forced closure until completion.
Temporary prepared windows detach geometry observers and close after transfer.
The live replacement owner retains only the current editor, so a retired cached
Log/Resolve caller can be recreated without releasing the existing session.
Identity-checked registry callbacks cannot remove a newer cached caller.

The Debug build and grouped native File/Open, existing Open, two-pane editor
and three-pane merge receiver passed. Core was unchanged and was not rerun.
The first native failure identified a real 60-point frame growth during content
replacement. The owner now restores the previous frame, respecting the new
editor's minimum size and retaining its top position. That app repair repeated
the Debug build and affected native group. A subsequent receiver crash was traced
with NSZombie to an overreleased plain NSWindow; the fixture's temporary Save
window now disables release-on-close under Swift ownership. The final grouped
receiver passed after that fixture-only repair, without another application build.
Actual same-window/frame/delegate identity, invalid input, duplicate Open,
Close/Quit guards, dirty Cancel/discard and late answers, two/three/two transitions,
final close accounting, held Save completion and unchanged input bytes passed.
Existing Open/clipboard/picker, typing/selection/Undo/Save and merge reload
regressions also passed. See [validation evidence](qa/merge-editor-open-2026-10-14.json). Patch mode routes through the existing independently retained Review/Apply
workflow; it does not yet replace the current editor with the directory patch
view. Physical keyboard/menu/focus/VoiceOver, live cached Log/Resolve reopen gestures,
complete visual captures and signed grant/App Store acceptance remain open.
The local pass does not certify complete upstream File/Open or hosted CI.


## Patch replacement follow-up — partial native parity

File/Open patch mode now prepares a checked Review/Apply model before replacing
the original editor. A dialog owned by the editor handles file/target permission
and target suggestions. Failed preparation leaves the original editor available;
Cancel or parent closure retires the pending model and refuses late adoption.
Successful preparation transfers content, keyboard/delegate ownership and grants
into the existing window through the same geometry-preserving replacement owner.
Review/Apply now has scoped Open/Reload controls and dirty Save/discard handling
for returning to text comparison. Busy/Open/preparation states block duplicate
Open, normal Close and Quit. Temporary preparation windows are closed.

The Debug build and one grouped native receiver passed on their first run.
The patch replacement family verifies invalid-patch preservation, a real Git
preparation held at repository discovery and cancelled, Close/Quit fences,
checked model readiness before adoption, same window/frame/delegate across
text→patch→text, and unchanged input/patch bytes. The existing Review/Apply family
verifies plain-folder previews, checked subsets, edited Save, source preservation,
dirty Close and expired picker replies. Existing File/Open and Open-dialog
families also passed. All owned windows/helpers closed and the receiver was reaped.
Core code was unchanged and its suite was not repeated. The new family is also
included in the normal grouped editor receiver for CI. See
[validation evidence](qa/merge-patch-open-2026-10-14.json).

Earlier descriptions of patch File/Open always opening a separate Review/Apply
window are superseded for this route. The app's separate Tools/Finder patch
commands retain their existing standalone behavior. Physical file/target/better-
folder sheets, live Finder/menu/keyboard/VoiceOver, exact light/dark captures,
forced-parent-close during every preparation phase and signed grant/App Store
acceptance remain open. This local checkpoint does not prove full hosted CI or
complete upstream merge-editor parity.

## Source form and chooser ownership — October 17, 2026

The native Open form now aligns all five permanent path/Browse columns across
source Merging and Apply unified diff groups, with version/radios above and the
OK/Cancel/Help footer below. The selectable error area has reserved height.
Browse retains source current-path seeding, file versus directory choices and a
patch/diff filter with an all-files alternative. It accepts existing regular
files or directories of the requested kind before creating a new access lease.
Drops share that validation; typed paths retain existing explicit authorization.

Each choice captures the full form, slot and window. Changed fields/mode,
retirement and duplicate answers cannot publish a path or retain a new grant.
Native cancellation ends the owned sheet; an independently counted choice keeps
Quit blocked until its callback/async response drains, even after forced closure.
Cancelled choices return focus to their path field. Scoped completion rejects
retired/busy inputs and delayed completion also checks the current enabled field.

Open submission captures its successful mode and refuses reentrant callbacks.
A preparation error restores editing for retry; successful acceptance remains
single use. Retirement clears delivery callbacks and disables controls. The
existing immutable patch bytes, standalone input order and text/patch editor
replacement owners remain authoritative.

All 24 resource controls have explicit partial mappings. The Debug build and all four grouped native families pass: source form/chooser ownership, standalone Open, text replacement and patch replacement. The affected source case passes again after the footer-spacing repair. Both raw light/dark captures were individually reviewed; all five receivers were reaped and independently absent. Core was unchanged and not repeated. See [batch evidence](qa/merge-open-source-family-2026-10-17.json) for the fixture compile repair, captures, diagnostic warnings and acceptance limits. Physical sheets, keyboard/drop/completion,
VoiceOver, source single-pane pruning, all replacement transitions and signed
App Store authorization remain open; this is not complete dialog certification.
