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
comparison. Editing the patched result and hunk-level application remain pending.

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
and editable patch-result saving remain pending.

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
index. Native checkboxes use this backend; editable before/after comparison remains
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

Editable before/after patch merge panes, hunk/line application and
the full Git configuration settings page remain pending. The source's exact context-menu/keyboard behavior remains pending. Physical keyboard/accessibility,
light/dark visual comparison, signed sandbox access for files outside the repository,
deployed Finder integration and App Store acceptance are unverified. No screenshot
or release-readiness claim covers these hidden native checks.
