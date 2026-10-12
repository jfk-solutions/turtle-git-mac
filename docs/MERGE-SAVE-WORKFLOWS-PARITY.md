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
