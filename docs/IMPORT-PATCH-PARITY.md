# Import Patch port

The native **Apply Patch Serial…** command imports mail patches using `git am`.
Open it from the Repository menu or sidebar, or the TurtleGit Finder menu in a
known working tree. Add patch files, check the ones to import, order them with
Up/Down, review the Patch tab, and choose Apply. This is a partial native port;
the remaining parity work is listed below.

Pinned source: `7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseProc/ImportPatchDlg.cpp/.h`.

## Engine

`GitRepository.importMailPatch` invokes Git's mail-patch importer with literal
argument arrays and an explicit `--` before the file path. The source defaults
are preserved: Three-way, Ignore space change and Keep CR enabled; Sign-off
disabled. Git retains mail author/date/message metadata and creates commits.
An active import prevents starting a second one. Git failures retain recovery
state rather than automatically discarding it.

The worktree-specific Git paths distinguish an `am` session from either rebase
backend. Abort, Skip and Resolved run the exact source `git am` recovery commands
only for mail application; they cannot accidentally abort a rebase. Linked
worktrees have independent session state. The API accepts existing readable
local files, supports streamed Git output and cancellation, and rejects invalid
files or pre-cancelled requests before invoking the importer.

## Verification

`python3 scripts/test-mail-patch.py` runs five real-Git cases. The four-engine
record is [mail-patch QA](qa/mail-patch-2026-10-08.json). Cases cover Unicode
mail paths with a leading dash, author/date/body/sign-off preservation, real
conflicts followed by Abort/Skip/Resolved, rejection during an actual apply-backend
rebase with exact HEAD/index preservation, linked-worktree isolation, invalid
file/non-file URL and cancellation before mutation.

## Native dialog

Checked paths, Add/Remove/Up/Down, the four source option defaults, Patch/Log tabs,
and per-row Applying/Success/Failed/Skipped state are implemented. Stable row IDs
preserve checks, selection and results while reordering. Options and input rows
are fixed for the active batch, with model guards as well as disabled controls.
A successful row is not re-imported when continuing after a failure. A skipped
row can be checked again to make it eligible for a later attempt.

On a failed import, resolve and stage conflicts before choosing Apply again;
the recovery prompt offers **Abort / Skip / Resolved / Cancel**. Abort restores
the failed row for retry; Skip/Resolved mark it only when Git finishes that
session. Additional failures retain recovery state. For a pre-existing external
session, recovery does not incorrectly mark the first newly added patch done.
An active rebase is refused. Before importing, author and committer name/email
are checked using environment overrides, role-specific configuration and user
configuration in that order. Git validates both identities. Missing fields offer
Configure or Cancel; Configure opens a native name/email sheet with repository
and global scopes. Saving retries the check; Cancel applies no patch. Existing
author/committer overrides remain in effect. This is the identity portion of the
upstream Git settings workflow; the full Git configuration page remains pending.

[Identity QA](qa/import-patch-identity-2026-10-08.json) checks cancellation and a
name-only configuration followed by email configuration, then two real imports
retaining the patch author and the configured committer. Configuration callbacks
are injected: physical sheets, global writes and signed access remain unverified.

**Abort** while a batch runs stops after the current Git command; it does not
kill that command or close the window. Idle Cancel/window-close checks the Git
session and offers Abort, Keep session or Cancel. Failed aborts keep the window
open. If repository access or the Git session check fails, an explicit **Close and
keep state** choice allows the idle window to close without attempting recovery;
Cancel keeps it open. Cancel is the safe default. Quitting is refused during an operation or attached sheet.

Idle application Quit now defers termination and checks each open Import Patch
session with the same Abort/Keep session/Cancel choices as window-close. Cancel
or a failed abort cancels Quit; Keep retains Git state. An unavailable repository
requires the explicit keep-state choice. Import controls and close stay locked
while the application completes all quit confirmations, then unlock if Quit is
cancelled. The session check does not close the dialog prematurely.

[Quit QA](qa/import-patch-quit-2026-10-08.json) checks the actual application
delegate with a real conflicted import and captures termination replies rather
than terminating the receiver. It verifies Cancel/Keep/Abort, repeated Quit while
pending, session preservation/cleanup and control unlocking. Physical sheets and
multi-document quit cancellation remain unverified. Patch-file
security-scope leases and repository access remain retained by the model.

The command uses the original patch icon in the app and Finder. Finder command
ordering and the pinned folder/patch-file conditions are mapped; selected `.patch`
and `.diff` files in a known working tree prefill the dialog. Finder's existing
repository authorization still applies. File selections outside known working
trees and the source's repository chooser remain pending. Geometry uses the
source `ImportDlg` identity. Patch preview uses the shared unified-diff font, tab size and light/dark line palettes, including added/removed backgrounds and header/hunk colors. Log text uses the shared log font; Git output is
buffered until each command returns, matching this source dialog's workflow.

`python3 scripts/test-import-patch.py` checks the real native table and preview,
row movement/checks, fixed batch input/options, two real mail commits and sign-off,
retained conflict cursor and all recovery choices, Cancel/Keep/Abort close choices,
and a slow real Git hook proving that batch stop completes the current command.
The [native QA record](qa/import-patch-native-2026-10-08.json) records four Git engines.
[Unavailable-session close QA](qa/import-patch-close-2026-10-08.json) additionally
checks Cancel and explicit close with a temporarily moved Git directory, preserving
the real active import session, HEAD, index and working file.
Finder checks cover menu order, conditions, icons and routing metadata; they do
not prove a deployed Finder extension.

## Patch-list commands

For one selected row, **View Patch** opens the read-only unified diff viewer.
Double-click has the same action. The file is read as original bytes, independent
of the text preview; Save As preserves those bytes. The existing Unified Diff
Viewer setting and Shift inversion choose the configured external viewer or the
built-in viewer. External handoff uses an app-owned byte snapshot.

**Send Mail…** is available for one or more selected rows and passes attachments
in patch-list order to macOS email composition. The user composes and sends the
message in their mail app. No mail service produces a visible error. File access
leases stay retained through the service callback, and viewer handoff/composition
block concurrent import, row mutation and window close. Failures re-enable the
controls. Context icons follow the application context-menu icon setting.

The source's **Review Patch with TortoiseGitMerge** command opens a working-tree
review/application workflow, separate from the serial `git am` import. The single-row **Review Patch with TurtleGitMerge** command now opens a native
window with a checked file list, original colored patch preview, applicability
results, reverse/strip options and selected complete-file application. Successful
files are marked Applied while remaining files can continue from the original
snapshot. Changed options require Refresh before Apply. Review changes the working
files without staging or creating commits. Parent import/close/quit operations and
child patch operations guard each other. The file access lease stays retained.

[Native review QA](qa/patch-review-native-2026-10-08.json) covers the actual hidden
AppKit table and preview, selected application/continuation/reversal, exact HEAD
and index preservation, busy close/Quit/options guards and injected context
handoff/failure recovery. It does not establish physical menu gestures or visual
comparison. Edited result saving is implemented below; hunk-level patch-engine application remains pending.

The **Compare** tab now shows the focused file before and after the patch, with
aligned rows, source Merge colors, line numbers, linked vertical scrolling,
difference navigation and native Find. Selecting another file refreshes its
comparison; the Original patch tab retains the entire unchanged patch. Content that cannot be decoded as text shows a bounded hexadecimal preview,
with exact bytes kept
in the comparison snapshot. Absent files and file modes are shown explicitly.

To produce the after image, the Core backend copies only the selected path
operation's current inputs into a private temporary repository, applies the
original bytes with the same reverse/strip/include and local whitespace policy,
then returns exact before/after bytes and removes the temporary directory.
Parent symlinks are rejected for original reads and temporary copy/result paths.
Forward and opposite-direction Git metadata are paired in opposite record order
so renames use the correct preimage. Current files, HEAD and index are untouched.
A conflicting focused file reports a preview error; other checked applicable
files can still be applied.

[Before/after QA](qa/patch-comparison-2026-10-08.json) records real-Git Core
text/binary/rename/mode/add/delete/reverse, unusual-name, symlink, local whitespace
policy and stale/unsafe/foreign-review checks. The native receiver checks the
hidden before/after text controls, palette, ruler, Find, file selection, linked
scrolling and difference navigation. Physical visual/accessibility acceptance
remain pending.

The Core review/application backend now keeps original patch bytes, obtains Git's
statistics and summary, and checks applicability without staging or committing.
Application rechecks the same byte snapshot against current files and invokes
whole-patch `git apply` without index/reject/unsafe-path options. Reversal and
explicit path strip counts are supported. Reviews are bound to their repository.
Git handles text, binary payloads, renames, mode changes, additions and deletions.
The review also exposes Git's ordered NUL-delimited file statistics: raw path
bytes, display path, added/deleted line counts and binary markers. Tabs/newlines
in names are preserved; reverse reviews expose reverse counts. Rename statistics
name the resulting destination; they do not provide the original source path.
Raw non-UTF-8 path bytes remain available separately from the display string.
[File-list QA](qa/patch-file-list-2026-10-08.json) covers actual Git patches with
tabs, newlines, Unicode, leading dashes and binary entries, plus incomplete
metadata rejection.
[Working-tree patch QA](qa/working-tree-patch-2026-10-08.json) verifies real files,
unchanged HEAD/index, stale-review rejection and unrelated local changes. This
backend does not establish per-file before/after review, editable merge panes,
hunk/line application or complete TortoiseGitMerge patch-engine parity.

The Core backend can now recheck and apply selected complete files, even if the
whole patch cannot apply because an unselected file conflicts. It uses escaped
literal path patterns with [Git's include filtering](https://git-scm.com/docs/git-apply),
then checks that Git returns exactly the selected paths/record counts. Applying
retains those filters and checks current files again. Binary files and renames
remain complete operations; the original patch byte snapshot is preserved.
All repeated records for a selected path must be selected. Empty/unknown IDs are
rejected. Per-file selection requires UTF-8 paths; whole-patch application keeps
raw path bytes through Git. [Selected-file QA](qa/patch-file-apply-2026-10-08.json)
checks literal wildcard/backslash names, an unselected conflict, sequential
rename/binary/remaining-file application and reverse rename without changing the
index. Native checkboxes use this backend; full conflict/hunk-level patch review remains
pending. The source suppresses the generic
Apply context command in Import Patch; this native list does too.

The headless receiver checks source selection conditions, exact UTF-16 bytes and
read-only export, filename/Shift handoff, attachment order, operation guards and
failure recovery through injected callbacks. It does not launch an external app,
compose or send mail, or simulate native mouse/menu events. Real context-menu,
double-click, external application and mail-service acceptance remain unverified.
See [patch-list command QA](qa/import-patch-context-2026-10-08.json).

## Preview text and appearance

The embedded preview now uses the same read-only diff control as View Patch.
Shared Unified Diff appearance settings control the font, tabs and line colors.
Selection updates keep the original file bytes for export; import still passes
the original file path to Git. The display decoder recognizes UTF-8/16/32 BOMs,
checks UTF-16/32 byte alignment, and otherwise uses UTF-8 with a Windows-1252
fallback. Other locale-specific legacy encodings remain unsupported.

The source's **250 MiB** preview threshold is preserved. A file at or above that
size shows an inline notice and remains importable; the notice does not become
an exportable patch. Failed reads also show an inline notice. Multiple selection
clears the preview, and generation guards prevent old reads replacing the
current selection.

[Preview QA](qa/import-patch-preview-2026-10-08.json) checks actual hidden AppKit
text attributes for default light/dark added-line colors and a custom shared
font/color. It also checks BOM display and original-byte export, a sparse 250 MiB
fixture and multi-selection clearing. These checks do not establish screenshot
or physical accessibility acceptance.

## Embedded Find and Escape

The preview's Find context command now opens the native Find bar directly from
the text control, including in ordinary dialog windows. With preview focus,
Command-F opens Find and Command-G/Shift-Command-G route to next/previous match.
Escape dismisses an open Find bar and returns focus to the preview; another
Escape requests window close through its delegate, preserving the import's
session and operation guards. The standalone diff viewer uses the same Find
implementation.

[Embedded Find QA](qa/patch-embedded-find-2026-10-08.json) invokes native actions
in a hidden ordinary window and verifies Find-bar visibility, focus restoration
and guarded close dispatch. It avoids shared Find-pasteboard writes and synthetic
key events; search matching and physical keyboard acceptance remain unverified.

## Edited patched results

Enable **Edit patched result** in Compare to edit the right pane. The left pane
stays immutable. The shared native aligned editor retains source row gaps,
Undo/Redo, block context commands with original icons, and encoding/line-ending
controls; display gaps never become saved file bytes. **Save patched result**
(or Command-S) applies that focused result. **Discard edits** returns to the
original proposal. File selection, refresh, path options, checks and bulk Apply
are guarded until editing finishes, preserving the current draft.

Close and application Quit offer Save / Don’t Save / Cancel for a dirty result,
with Cancel the safe keyboard default. A failed save retains the draft and cancels
closing/quitting. Don’t Save during Quit does not clear drafts prematurely, so
another document can still cancel the overall quit. Closing the parent Import
Patch window resolves its dirty review child first. Parent imports are guarded
while the child is editing.

The save backend validates the captured input bytes, file modes and permissions,
including a rename destination that was absent. It creates private raw-blob Git
trees for before/edited-after states, generates a binary-capable patch, checks
current files again and applies it without committing. The private index and
objects are removed on completion; user index entries are retained unless Auto
Add applies. Encoding/BOM, line endings, missing final newline and edited trailing
spaces are preserved. Private trees use the repository’s SHA-1/SHA-256 format.
External writers are not globally locked.

Following `CMainFrame::PatchSave`, saving a zero-line result removes the file.
**Settings → TurtleGitMerge → General → Add new files to Git after saving a
patched result** follows the source Auto Add preference, enabled by default.
Only a newly created destination is added; existing-file edits and rename source
deletions are not automatically staged. A failed Add reports that the result was
saved and does not repeat the file mutation.

[Edited patch QA](qa/patch-edit-save-2026-10-08.json) records Core real-Git
rename/mode saves, zero-line removal, Auto Add success/failure, stale collision
and foreign-review refusal, and SHA-256 UTF-16/BOM/CRLF/whitespace preservation.
Native checks use actual aligned text input, Undo/Redo, format-preserving saves,
draft locks, captured Quit replies and injected Save/Discard/Cancel choices.
Physical sheets/keys/menus, signed sandbox access, comprehensive marked-block
and format-menu behavior, rejected-hunk conflict panes, and full source parity
remain unverified or pending. Symlink/binary editing remains unavailable; the
original selected-file application still handles those complete operations.

## Whitespace markers

The shared native diff control draws space dots and tab arrows, matching
`CSciEdit::SetUDiffStyle`'s always-visible whitespace. Marks use the visible
AppKit glyph layout and do not replace text characters. Copy, search, selection
coordinates, accessibility text and original-byte export keep their existing
content. Light mode uses the native secondary label color; dark mode uses the
source 180/180/180 marker color, and increased contrast uses the label color.
The Log tab keeps its separate plain-text control.

[Whitespace QA](qa/patch-whitespace-2026-10-08.json) checks actual native glyph
geometry, Unicode-adjacent spaces/tabs, offscreen exclusion, private-pasteboard
copy and original-byte export. It does not establish rendered visual or physical
accessibility acceptance.

## Divider layout

A native horizontal `NSSplitView` separates the patch list/options from the
Patch/Log tabs. The upper pane keeps its height when the window grows, and both
panes have minimum heights so the file controls and preview remain usable.
The divider position is stored in macOS points under the source `AMDlgSizer`
identity in TurtleGit's dialog-geometry namespace. Reopening restores the height
and clamps it to the available window space. Settings → Saved Data → Dialog sizes
and positions clears it together with window geometry, preserving appearance.
Existing open windows can save new geometry again when moved/resized.

[Divider QA](qa/import-patch-split-2026-10-08.json) checks the actual hidden native
split view through its public positioning API, save/reopen restoration, smaller
window constraints and Saved Data clearing. It does not simulate mouse dragging
or establish physical divider/accessibility acceptance.

## Dropped patch files

The patch table accepts native file-URL drops. Files append in provider order,
with directories and duplicate standardized paths skipped, following the source
`CPatchListCtrl::OnDropFiles`. New entries are checked. The Add panel retains its
separate source behavior and can add repeated paths.

While macOS loads the URL representations, row mutations, imports, further drops,
close and application quit are guarded. Failed providers report an error and
restore the controls; other valid files in the drop can still be added. File
leases use the same sandbox checks as Add. No extension filter is imposed.

[Drop QA](qa/import-patch-drop-2026-10-08.json) uses real `NSItemProvider` file-URL
representations to check ordering, deduplication, directory skipping, failure
recovery and operation guards. Physical Finder-to-table dragging and signed
sandbox access outside the repository remain unverified.

## Remaining parity work

Full patch conflict/merge engine, hunk/line application and
the full Git configuration settings page remain pending. The source's exact context-menu/keyboard behavior remains pending. Physical keyboard/accessibility,
light/dark visual comparison, signed sandbox access for files outside the repository,
deployed Finder integration and App Store acceptance are unverified. No screenshot
or release-readiness claim covers these hidden native checks.

## Prepared result Save As target

The native **Save As…** context action writes the selected pane's current draft
and encoding, then binds that pane to the chosen file and records a clean
baseline. Subsequent Save and owned Quit Save write that file. For a rebound
prepared result they do not apply the original patch, stage its original path,
or mark that proposal Applied. The internal explicit copy-export helper retains
its copy semantics for callers that request a copy.

A pending choice blocks editing, Save, refresh, file/options changes, reentry,
Close and application Quit. Cancel and write failures retain the draft and show
errors. Captured bytes and selected permissions live with the operation; retired
owners refuse late destination and empty-file responses. See
[Save As target behavior](SAVE-AS-TARGETS.md).

[The older copy-export QA](qa/patch-save-as-2026-10-08.json) covers that helper's
copy semantics, not the newer UI target binding. Physical save panels,
overwrite/symlink/permission variants and signed panel grants remain unverified.

## Send Mail Apply handoff

Send Mail's Apply Patch command now opens an independent native Apply Patch
Serial window containing the highlighted rows in their original order. Matching
inherited file grants are retained in the imported items, including output-folder
grants outside the repository. Default Add/drop behavior still acquires its own
file leases when no inherited grants are supplied. The child retains its normal
Apply/recovery/close behavior and survives closing Send Mail. Hidden real-Git
handoff checks are recorded in [command QA](qa/send-patch-tools-2026-10-10.json).
Signed sandbox acceptance and complete Import/PatchList/application parity remain
unfinished.

## Forced-close lifetime and successful OK result (October 11, 2026)

The importer now owns a cancellation token across identity queries, serial
imports, recovery and close/quit state reads. Ordinary Abort still finishes the
current command before stopping the batch, as in the source. A forced native
window close invalidates the model and cancels its current Git process; it
suppresses subsequent success/error/close replies and viewer handoffs. Existing
`am` state is retained rather than automatically aborted. The controller ends
its owned sheet and any pending prompt when closing.

The final OK action records successful acceptance separately from Cancel.
This is needed by Sync's modal Apply Patch caller: upstream ImportPatchDlg
applies the commits itself and clears m_PathList in OnBnClickedOk. Sync must
inspect the result after successful OK rather than applying those files twice.
Sync now opens this importer as an owned sheet and consumes successful OK
without reapplying files; its focused two-engine native checks pass. Approved
Cancel/OK explicitly ends the parent sheet before closing the window. Wider
checkpoint verification is tracked in [Synchronization parity](SYNCHRONIZATION-PARITY.md). Physical prompts, arbitrary mid-write cancellation, complete child
mail/editor lifetimes and signed access remain separate acceptance work.

Focused lifecycle groups and the full 24-group native regression passed with
system and packaged Git. Both unsigned builds, bundle audits, inventory and
site checks passed. The actual driver cleanup passed a forced timeout with
TERM refusal. See [verification scope and corrected attempts](qa/import-patch-lifecycle-native-2026-10-11.json).


The 2026-10-12 [single-patch directory-target batch](REVIEW-PATCH-PARITY.md) adds
the standalone app/Finder route and ordinary-folder/nested-folder support to
this existing review/editor. It retains separate `git am` serial import and its
working-repository requirement. Earlier dated constraints remain historical
records; the new audit lists the current implementation and remaining gates.

## Review operation ownership continuation — 2026-10-13

Single-patch Review now owns cancellation across metadata, checked-file
validation, disposable comparison generation, cached input checks, edited Save
and Apply. Busy work exposes Cancel operation; closing a busy window normally
waits, while forced closure retires its token and fences late UI publication.
Global operation counts keep Quit blocked until real cleanup, including draft
prompts and pane export choices whose windows were closed. Late Save/discard or
export destination replies cannot publish writes after retirement.

Canceled edited saves retain their draft and permit a checked retry. Apply/read
cancellation requires refresh before reusing the plan. Mutations that returned
success notify the captured owner even if UI retirement followed; unsuccessful
or canceled mutation attempts refresh that owner without claiming success.
Cancel is not rollback: changes already written may remain, and an optional Add
may be incomplete. The grouped 22-test Core check and six native cases passed across system and
bundled Git. The tests held review/selection/comparison/Apply/Save commands,
reaped their owned processes, and verified forced closure, draft retry, late
prompt/export fencing and global Quit ownership. The final compiler compatibility
rewrite passed the four affected partial-file tests and Debug compilation. See
[dated QA](qa/review-lifecycle-2026-10-13.json). Physical/signed acceptance and
older hosted compiler confirmation remain open.

## File patches batch actions — 2026-10-13

Compared `TortoiseMerge/FilePatchesDlg.cpp` Preview/PatchAll/PatchSelected.
The native file list now retains multiple highlighted rows separately from its
checked-file set. Original-icon Preview, Patch all and Patch selected context
commands accompany full-width Patch selected/Patch all buttons below the file
list, following the source panel placement. The existing whole
checked-selection operation remains available as Apply checked.

Patch all/selected operate in original list order, skip files already patched,
report individual errors and continue with later files. Duplicate records for
one path are grouped into one complete-file operation. Each file is validated
again immediately before applying, using the original captured bytes and target
options; HEAD and index are not changed. Successful rows show green Patched;
failed rows show red Error with the Git diagnostic. Fixing a failed target allows
retry without applying the successful files again. Highlighting does not change
checkboxes. Captured menus are fenced by the loaded file-list generation.

Cancellation retains completed results, stops before the next file and requires
Refresh to inspect potentially interrupted changes. Closing/retiring the viewer
retains its existing owned cancellation, grants and late-result fences. The
repository owner still receives settlement after a mutation even if the viewer
was closed. Physical menu/layout acceptance, initial failed-hunk/conflict counts,
source conflict-editor behavior and signed App Store execution remain open.

Nineteen focused Core tests, four grouped native cases across system and bundled
Git, Debug compilation and two documentation tests passed after compilation
repairs. The native cases also retain the existing owned cancellation/retirement
checks. All owned receivers were reaped. See
[dated file-patches QA](qa/file-patches-2026-10-13.json).

## Displayed file-panel comparison — 2026-10-13

Compared the pinned `TMerge_PatchWindow.png`, `IDD_FILEPATCHES` and its command
strings. The displayed list now uses Path/State with native file-type icons,
basename labels/full-path tooltips, a bold preview row, muted patched rows and
red error rows. Source captions are Preview patched file, Patch all files and
Patch selected files; the panel buttons read Patch selected item/Patch all items.
The list is bounded in width so the comparison gets most of the window.

The earlier checkbox/Changes columns and Apply checked footer were removed from
this dialog to follow source selection semantics. The engine's atomic checked
selection API remains available internally; ordinary Review users now operate
on highlighted rows or all remaining items. Older checkpoint descriptions refer
to that preceding UI. Serial git-am import retains its source checked list.

An isolated preview of the real Debug app objects displayed actual per-file
results and colored original patch in both appearances. A physical Patch all
operation in the preceding layout patched README and the test file, preserved
an independently edited source file and reported its error. Final-layout theme
controls and context command labels were inspected; final fixture states were
prepared through the same real model/Git workflow. The four grouped native
cases passed with system/bundled Git. Every preview and receiver was reaped.

The preview must include the merge helper plus its packaged Git/Subversion
libraries; a reduced fixture first lacked those and displayed hex fallback.
One intermediate native automation connection dropped and that preview exited;
its attempted selected-file operation is not counted as successful acceptance.
Initial comparison viewport clipping was also observed in an intermediate
before/after view. Applied-file preview behavior, viewport initialization,
initial failed-hunk counts, full keyboard/VoiceOver and signed execution remain
open. The published captures show the Original patch tab and do not certify
those pending comparison behaviors.

See [display QA](qa/file-patches-display-2026-10-13.json).

## Preview dispatch and failure states — 2026-10-13

Rechecked `FilePatchesDlg.cpp`'s Preview switch and double-click handler. They
ignore already-patched rows and report rejects for error rows. The native
preview now preserves its shown file when those rows are highlighted: patched
rows do not trigger a read, and failed rows reuse their recorded diagnostic.
Invalid row IDs are refused. Reload also stops substituting another file for
an explicitly focused patched row. Errors are presented inline as a native
adaptation; the source's modal reject presentation remains separate acceptance.

The Compare pane distinguishes a running comparison, an engine failure and a
binary/undecodable file. An engine error is shown as its actual diagnostic.
Decoded text with no alignment gets a rebuild-preview message, rather than a
binary hex label. A save error with a valid alignment retains the text/editor
and its existing error display. Processing uses an explicit progress indicator.

The prior displayed check's applied-row-preview concern is resolved for the
source no-op/diagnostic dispatch contract. Initial viewport clipping, source
failed-hunk/conflict counts, physical modal/keyboard/VoiceOver behavior and
signed acceptance remain open. Existing gallery captures record their earlier
Original patch tab checkpoint. Focused native evidence follows this change;
no full Core suite is required for these native presentation/dispatch changes.

Debug compilation, four unique grouped native cases across system/bundled Git
and two documentation tests passed. State assertions require a real comparison
editor; those two engine cases were repeated after tightening that fixture. All
receivers were reaped. See [preview-state QA](qa/patch-preview-states-2026-10-13.json).


## Connected preview placement and viewport batch — October 14, 2026

Commit's View Patch/Partial Staging/Partial Unstaging now share the existing Log
screen-aware placement and sticky-edge geometry. A preview opens to an available
side or within a visible screen, reuses its frame across mode changes, snaps near
a parent edge and follows parent move/resize only while docked. Moving it away
leaves it independent. Minimize hides it; activation/restoration raises it without
stealing the parent's focus. Ownership, busy/close guards and preference semantics
remain in the Commit controller. Native left-side/screen clamping and the eight
point gap are platform adaptations to upstream PatchViewDlg's right-edge frame.

Unwrapped patch text now has a measured document extent after layout and viewport
resize, preserving horizontal access to long lines. Replacing the patch resets
selection and scroll to the start, matching PatchViewDlg::SetText. Appearance
updates retain position. Comparison initial selection/first-difference navigation
waits until wrapping, text extent and a nonempty viewport are available before it
is consumed. The same path handles queued edit caret and combined-pane requests;
closed comparison owners retire these geometry callbacks.

The Debug build and six unique grouped native cases passed with system/bundled
Git after the recorded closure-capture and fixture repairs. Passing system viewport
checks were not repeated. All owned receivers were reaped; no Core suite was run.
Light/dark Partial Staging compositor captures were inspected and published in the
gallery. See [batch evidence](qa/preview-viewport-2026-10-14.json). These changes
address the preceding placement and initial-viewport gaps, but do not certify all
physical side-by-side placement, keyboard,
VoiceOver, all monitor/fullscreen layouts, signed grants or complete dialog parity.


## Review output ownership — 15 October 2026

Review now treats pane Save As, unified-diff creation and format choices as
owned editor operations independently of the shared busy flag. File selection,
reverse/strip, refresh, draft Save/discard and replacement remain fenced while a
choice is pending. The Review progress row exposes Cancel operation during pane
or patch output. Cancel suppresses subsequent destination writes; it does not
roll back a write that already completed. Retry creates a new captured request.

Pane output captures its bytes, encoding, filename, folder, chooser and source
permissions before presentation. Unified-diff output captures its input document,
context and Git executable and forwards the owned cancellation token to the
existing generator. Both retain Quit ownership through forced closure until the
choice/generator settles; stale replies cannot write or publish errors. Only the
request's own save panel is canceled. Native save-panel destination grants and
source grants remain alive through the atomic write or generator cleanup.

Format choices share the same reentry/Close/Quit fence and retain permissions
until the reply settles. A choice applies only to its original live generation,
draft and encoding; retirement suppresses it. Review's recreated editors retain
both source-patch and repository access leases.

The older full fixture attempted Change Encoding immediately after insertText,
while the authoritative comparison engine was still filtering and correctly
refused that command. It now waits for the actual command gate and verifies the
chosen encoding before testing export locks. This repairs the setup rather than
removing its pending-option or byte-preservation assertions.

This remains copy export. Upstream FileSaveAs target retargeting, complete
physical sheet/layout comparison and signed sandbox/App Store acceptance remain
open. The existing defaults and normal import/patch behavior remain covered by
the full native fixture, with separate ownership cases for held choices,
Cancel/retry, active generator cancellation and forced-close late replies.

The prepared native editor now stays mounted while the authoritative engine
refines provisional rows; a progress overlay replaces the former view swap.
This preserves the actual text view/coordinator, selection and Undo manager
across typing and engine completion. The fixture checks editor identity and
Undo availability, then restores both the original draft and captured encoding.

Prepared comparison errors now appear inline with a Dismiss action, including
copy/patch destination failures while a usable alignment remains. This avoids
silently retaining an error on the embedded editor model or replacing the editor
with a modal error prompt that would interrupt draft recovery.

Successful Save patched result now retains the same native completed preview,
matching `FilePatchesDlg::SetFileStatusAsPatched` and `CMainFrame::SaveFile` rather
than clearing it or jumping to a different file. Core returns the exact saved
content, encoding and deletion state, including successful writes followed by
optional Add failure. The existing editor adopts that clean baseline, clears its
completed-file edit history, and displays saved byte counts/mode. Completed rows
remain protected against another patch/save; the user selects another file to
continue. Full upstream editable history after saving remains unverified.

The subsequent [source target batch](qa/save-as-targets-2026-10-15.json) records
source Save As rebinding, later Save/Reload and owner-approved Quit Save checks,
with remaining acceptance limits.

## Native file-panel interaction — October 16, 2026

The [AppKit file-panel batch](PATCH-FILE-PANEL-PARITY.md) replaces the SwiftUI table
and separates highlighting from explicit preview, matching the source notification
handlers. It adds native Return/context-key routing, captured menus and file-list
hiding/restoration with scoped Review main-menu commands. Existing per-file
application, draft/export and plain-directory/real-index rules are retained.
See the linked audit for grouped evidence and remaining full-family acceptance.

The [recorded-base recovery continuation](PATCH-RECOVERY-PARITY.md) adds initial
Ready/Conflict/Error classification, versioned-base retry, an embedded native
three-pane preview and clean-merge Patch all/selected continuation. Earlier text
listing all initial-state and conflict preview behavior as absent is historical;
the continuation records the implemented paths and remaining special-file scope.
