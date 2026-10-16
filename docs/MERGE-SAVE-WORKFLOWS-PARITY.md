# Merge save workflows

Baseline: `7338078f8ddd924b8cddee35f512f2286072136d`,
TortoiseMerge MainFrm.cpp::FileSave (Backup and DELETEWHENEMPTY) and
Resources/TortoiseMergeENG.rc's Backup original file and Delete/Cancel choices.

## Backup original file

Merge Editor Settings exposes **Backup original file**, default off as upstream.
Apply persists the option; Cancel restores the draft through the existing
settings transaction. Normal two-pane and three-pane saves read that option.
Save As/export remains separate and does not create a backup.

When enabled, an existing working file's captured original bytes and permissions
are written to its `.bak` sibling. A later save replaces an existing regular
backup, matching the source replacement behavior. Directories and symlink backup
targets are refused. A deleted/absent working file does not replace its existing
backup when saved again. Standalone saves retain the existing parent-folder grant
path; repository saves retain the covering repository grant in Store builds.
Signed security-scope acceptance remains open.

The macOS writer prepares output bytes and permissions in a temporary sibling,
validates the captured working snapshot, prepares/replaces the backup and validates
again before the final replacement or deletion. This adapts the Windows move-
original-first path so preparation failure does not remove the original. Temporary
siblings are removed on failure. It does not promise a multi-file transaction,
exclusive external-writer locking or crash-durable/fsync semantics.

## Empty result: Delete or Keep

Both native Save owners ask **File is empty** for a result with zero characters,
independent of a selected format's BOM. Delete removes that working file;
**Cancel — Keep Empty File** saves the empty result in the selected encoding.
Escape chooses Keep, matching the source Cancel's final retained-file behavior.
Whitespace or an actual blank line with a line ending is not a zero-line result.

The native sheet asks before the write; upstream asks after writing the empty
file. The resulting Delete/Keep states match, and cancellation does not leave a
partially prepared file. The captured choice enters the same guarded save path.
Busy, Quit, retired and already-sheet-owned windows refuse new Save dispatch.

Two-pane saved documents record an explicit deleted state, with their previous
encoding/permissions retained. Their blank editor can recreate the absent file
on a later Save. An external recreation fails captured-state validation. That
later Save retains the existing backup. The pane's file metadata says Deleted.

Three-pane Delete leaves unresolved index stages unless Mark as resolved was
requested. Mark as resolved stages the deletion with the exact captured path.
An index-lock/staging failure returns the refreshed absent working snapshot for
retry. Retry does not overwrite the original backup, lose the empty result,
commit or continue a merge/rebase. HEAD and unrelated paths remain unchanged.

## Grouped evidence and remaining work

Forty-three Core tests passed with zero failures, including exact UTF-16 BOM/CRLF
backup bytes and executable permissions, replacement, deletion/recreation, stale
working snapshots, directory/symlink backup refusal, temporary cleanup, empty
Keep/BOM, defaults/persistence and real conflict deletion with locked-index retry.
Existing comparison editing, conflict saves and engine presentation cases passed.
The first build caught a missing weak window reference for the new owned sheet;
that was repaired before the successful grouped run.

The unsigned Debug app build passed. Native Save-choice and backup checks use
injected decisions in actual production owners; these do not certify physical
sheet button/key interaction. See [the batch record](qa/merge-save-workflows-2026-10-12.json).
One combined native receiver passed both production owners: empty Keep/BOM,
backup replacement, Delete capture, Unicode/UTF-16 recreation, three-pane deletion
and explicit resolution preserving the original backup. Existing locator,
regex/comment, Undo/save and cancellation checks also passed. Every owned window
and helper closed; the installed main application was not launched.

Remaining: physical Delete/Cancel/Escape and Settings Apply/Cancel, failure UI,
close/Quit while the sheet is active, cross-platform empty-format edge cases,
minimum-OS and signed sandbox acceptance, complete merge/editor/application parity.

## Source Save As targets

Source pane Save As now establishes a new file and clean baseline. Later Save
uses the same guarded backup/empty-result rules described above; initial Save As
uses its atomic destination write. Repository merged-result copies retain their
separate behavior. See [target semantics](SAVE-AS-TARGETS.md).

The subsequent [source target batch](qa/save-as-targets-2026-10-15.json) records
source Save As rebinding, later Save/Reload and owner-approved Quit Save checks,
with remaining acceptance limits.

## Read-only Save As and owned save decisions — October 16, 2026

The pinned FileSave redirects a read-only output to FileSaveAs. Compare now does
that within its normal Save transaction, including Save All and owner-approved
Quit Save. Cancel leaves the draft dirty. A successful selection binds only that
pane to the new file; later Save/Reload and backup behavior use the selected file.
Original permissions are preserved, and read-only or symbolic-link output targets
are refused rather than made writable or followed. Explicit Save As retains an
existing regular destination's executable mode.

Three-pane Save likewise redirects a read-only working result or selected output.
A repository conflict saved to a different file retains its original worktree and
index conflict. The new result target gets later Save/Reload, backup, empty-file
Delete/Keep and recreation behavior; Mark as resolved is disabled for that target.
The window and result caption name the chosen file. Ordinary repository result
export remains a separate copy until a result target has been rebound; complete
unification of all explicit result-export commands remains open.

Initial Save As writes an empty regular file without Delete/Keep or backup. Normal
saves ask the existing empty-file question and honor Backup original file. Automatic
PatchSave retains its separate zero-line deletion/no-backup path. This distinction
comes from upstream FileSaveAs, FileSave and PatchSave rather than a new global
empty-file policy.

Marked-block, empty-result and unresolved-conflict questions are now owned sheets.
An operation token and retained grants cover each pending decision and write.
Programmatic cancellation dismisses only that operation's sheet/panel and aborts
the save; the visible empty-file Cancel button still means Keep Empty File, as in
the source. A forced close fences late choices before writing and suppresses stale
failure UI. Close, Quit, duplicate Save, Open/Reload and editor changes stay gated
until the pending operation settles. Normal failure retains the draft and permits
retry after the underlying problem is fixed. No exclusive external-writer or
multi-file atomicity guarantee is added.

The read-only Core checks include captured permission bits even for a process
whose effective privileges would otherwise make the path appear writable.
Physical sheet keyboard handling, signed sandbox/Keychain/Finder acceptance,
minimum-OS runtime and full application parity remain open.

A rebound repository result also reloads independently after the original index
conflict has ended, retaining the captured source panes. Signed Store builds
still need acceptance of parent-folder authorization for temporary/backup sibling
writes at rebound destinations; retaining a selected-file lease alone is not
evidence that every such write is permitted.

The [save ownership checkpoint](qa/merge-save-ownership-2026-10-16.json) records
50 passing focused Core cases and twelve passing native case/engine runs. New
save and retained target checks, ignored-conflict workflows, patch recovery and
full import ownership ran with both Git versions; retained engine/history/colors
and formatting also passed. Seven failed fixture/diagnostic runs are recorded,
including legacy encoding, saved edit-state and native readiness assumptions.
Only affected cases were repeated; no product guard or state assertion was
removed. All nineteen owned receiver processes were reaped and independently
absent. Both Debug builds passed. These checks do not certify complete hosted CI,
physical UI parity or signed deployment.

## Containing-folder authorization — October 16, 2026

Store editor writes now require a live grant covering both the destination and
its containing folder. A selected-file grant is sufficient for reading that file;
it does not establish permission for a temporary replacement sibling, `.bak` or
recreation after deletion. Existing repository/folder grants are reused, including
related scopes retained with a source Save As target. An ordinary unrestricted
build does not show this additional panel.

Compare normal Save/Save All/owner-approved Quit Save, read-only Save As, pane
Save As/export and unified patch output use the same folder-access owner. Merged
results and source/result exports use that owner too. If no existing grant covers
the folder, an owned directory-only panel asks for it during the explicit save.
The selected folder must cover the intended destination and its parent; a sibling
folder or leaf-file selection cannot authorize the write. Cancel retains the draft
or existing destination and permits retry. This is a macOS sandbox adaptation;
upstream FileSave/FileSaveAs/PatchSave backup and empty-file rules stay distinct.

The operation retains its old and newly acquired grants through pending choices,
writing and completion. Busy, duplicate Save, Open/Reload, ordinary close and Quit
share the existing save/export fences. Cancellation or forced retirement dismisses
only the owned panel and checks the captured token before acquiring a late grant,
writing, rebinding a pane or publishing an error. Source exports retain covering
folder grants with the returned file lease for later saves.

Injected scope-provider checks can prove containment, lifetime and action routing
in the unsigned app. They do not prove the OS will grant access in a signed Store
build. Actual signed panel/bookmark behavior, entitlement acceptance, minimum-OS
and full Finder/App Store distribution remain required.

The [folder-access checkpoint](qa/merge-save-access-2026-10-16.json) records nine
distinct passing native case/engine runs: the new access workflow, retained save
and target ownership, source exports and full import output/format ownership.
Two access runs repeated after correcting older Store checks to honor covering
and related folder scopes. The final tests enable the same selected-target policy
used in Store builds, with injected grants. All eleven owned receiver processes
were reaped and independently absent. Core sources were unchanged, so its suite
was not repeated. Build repairs and the signed/physical acceptance limits are
recorded separately; no full hosted or signed Store pass is claimed.
