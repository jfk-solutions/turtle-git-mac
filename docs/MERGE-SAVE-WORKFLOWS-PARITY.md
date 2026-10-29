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
Delete/Keep and recreation behavior. Explicit Mark as resolved now stages that
chosen target through the standalone/rebound workflow described below.
The window and result caption name the chosen file. Ordinary repository result
Save As remains a separate copy until a result target has been rebound. This
distinction follows FileSaveAs versus source-pane SaveFileTo; those commands
should not all rebind the result target.

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


## Result-copy savepoints and shared source writing — October 17, 2026

Pinned `MainFrm.cpp::FileSaveAs` calls `SaveFile(fileName)` without changing the
merged filename. `SaveFile` clears the modified flag and marks the history's
original state. Repository-conflict result Save As now records the captured
text, encoding, line-ending and conflict-choice state as a clean savepoint,
while normal Save continues to target the original working file. Edits become
dirty against that savepoint; returning to it becomes clean. History is retained.
An external copy does not resolve or stage the original conflict. Saving over the
original file adopts the actual written snapshot so the next Save does not reject
our own write as external. Source/result overlaps update bound source snapshots.

Patch comparisons separately retain measured owned writes to input paths for
later stale-file checks and patch construction. Their original before/after
panes and new-file Add policy stay intact. Untouched paths and external changes
after the copy remain guarded. A copy to an external path does not apply the
patch or mark it completed. The parent uses the editor's current comparison when
normal PatchSave is subsequently requested.

Source and repository-result copies share the guarded atomic Save As writer.
Existing executable mode is preserved; read-only, symlink and non-regular
outputs are refused. Empty Save As creates a file and creates no backup.
Serialization is captured before the panel; writing and successful-save readback
run off the main actor. The selected file and covering folder scopes remain
retained through the callback. Close/Quit are guarded during a held write;
retirement cancels pending work and prevents late UI publication. Cancellation
cannot roll back an atomic filesystem write that already completed.

A normal repository save that writes successfully but then fails to stage records
that actual file as saved, reports the Add failure and leaves the index conflict
unresolved. It no longer carries a stale dirty baseline for the successful write.

Grouped verification is recorded in
[the batch record](qa/merge-result-copy-savepoint-2026-10-17.json). Physical panels,
Undo gestures, source alias variants, signed folder scopes and installed Finder
acceptance remain open; this does not certify complete merge or application parity.

## New outputs, Auto Add and retained-source preparation — October 29, 2026

Pinned `MainFrm.cpp::FileSave` captures whether the ordinary result was absent
and, with AutoAdd enabled (default), dispatches Add after saving the new file.
`FileSaveAs` does not apply that dispatch. In the pinned
`TortoiseProc/Commands/AddCommand.cpp`, however, the `/noui` body contains only a
compiled-out SVN placeholder: it does not stage Git data. The native real Git Add
is therefore an explicit functional adaptation of the setting, not a claim that
the pinned child command already performs it. `FileTextLines.cpp` creates missing
output ancestors. The setting already existed in TurtleGit, but ordinary
Merge/Compare results did not consume it and nested missing output parents could
not be saved.

The connected native implementation captures a directory identity plan before
an output permission question, authorizes the nearest existing ancestor, and
creates missing components through pinned directory descriptors. Symlink or
ancestor replacement refuses publication. Failed preparation removes only still-
empty directories created by that operation, preserving peer files. Existing
backup/empty-result/output CAS semantics remain in the shared writer.

Successful ordinary creation records its saved document baseline before Git Add.
Only initially absent, retained outputs participate; existing targets, Save As
and source copies do not. AutoAdd is captured for the Save attempt. An Add failure
or cancellation retains the saved file and exact receipt; a compact Retry Add
control retries that saved version without rewriting it. A reviewed ordinary
resave advances the pending receipt; disabling AutoAdd for that successful Save
retires the automatic intent. Explicit Save As rebinding does not retarget an old
Add receipt. External saved-file changes and conflicting raced index entries are
refused; unrelated staged entries remain unchanged.

A narrow output-folder grant is not a repository grant. Marker discovery stays
within live scopes before Git starts, selected roots must be actual roots, and
linked metadata/object folders require their own covering grant. New grants stay
owned through failure/retry. Native permission adaptation is separate from the
Windows child-process dispatch; this checkpoint does not prove signed grants.

Retained-source reads, replacement/reinterpretation, validation rereads and
result presentation prepare off the main actor, with one current owner accepting
the immutable result only after token/generation checks. The existing
`WorkingTextMerge` is already an actor: its synchronous `read` method is correctly
called with `await` and was never proof of main-thread execution. The earlier
inspection inference was corrected before implementation; no actor clone was
introduced for that reason.

The [new-output checkpoint](qa/merge-output-preparation-2026-10-28.json) records
18 focused Core methods and the grouped native fixture passing with system and
bundled Git. The final incremental Debug build exited successfully with one
retained contradictory exit-zero diagnostic; initial compiler failures and their
repairs remain in the receipt. Native-only corrections were rebuilt before the
passing native group; Core was not repeated. At that checkpoint, the explicit
unresolved-conflict Save Anyway/Mark as resolved override remained unimplemented;
the follow-up below addresses repository conflicts. Physical/signed permission
sheets, every filter/encoding combination, full hosted integration and whole-port
acceptance remain separate.


## Repository-conflict Save Anyway and Mark as resolved — October 29, 2026

Pinned `MainFrm.cpp::OnUpdateMergeMarkasresolved` (2230 onward) enables a writable
merged result even with conflicts. `OnMergeMarkasresolved` (2244 onward) first
calls `HasConflictsWontKeep` (3078–3105), then saves and dispatches Resolve with
`/noquestion /skipcheck /silent`. The selected Resolve command performs Git Add;
this is distinct from the compiled-out `/noui` AutoAdd placeholder described
above. The source warning defaults to returning to the first unresolved line;
only an affirmative save continues.

Native repository-conflict controls and the shared editor toolbar now admit that
warning instead of disabling Mark as resolved whenever marker/ignored conflicts
remain. Ordinary Save and Mark as resolved use the same owned three-choice
warning: Save Anyway, Continue Resolving (default Return), and Cancel (Escape).
The captions are native adaptations of the source command links/common Cancel.
Both negative replies keep the editor open and return to its first conflict.
No merged-result or index write precedes affirmation. Separately chosen source
copies retain their own save operation.

Affirmation belongs to one captured attempt. The current owner/window, document,
load/input/source-layout generation, serialized result, encoding, line ending and
ignored/source-choice presentation must still match after the warning and before
writing. Busy admission rejects a repeated command while the question is owned;
cancellation, retirement, or a changed draft cannot resume that stale attempt.
The Core unresolved override is an explicit per-call argument, defaults to false,
and is never persisted in the document or reused by a retry. Existing ignored-
conflict resolution bookkeeping remains separate from this explicit warning.

If the file save succeeds but Git Add fails or is cancelled, the still-current
editor retains the successful saved baseline, reports the stage failure, and
stays open. A later Mark as resolved attempt requires its own warning and still
checks external file/index changes; it does not reuse an old approval. Successful
staging reuses Resolve's bounded cleanup of the LOCAL/REMOTE/BASE source siblings;
BACKUP files and directories are retained. Failed or cancelled staging does not
run that cleanup. A Git Add that actually exits successfully is acknowledged even
if cancellation arrives with its completion.

The [connected checkpoint](qa/merge-unresolved-warning-2026-10-29.json) passed
20 focused Core methods and both Git engines for the new warning family and
affected ignored-conflict workflow. Actual native menu/default-button actions,
negative navigation, per-attempt/stale/retired replies, saved stage failure and
cancellation, and fresh approved retry are covered. Core checks also retain
unrelated state and bound successful Resolve cleanup to its source siblings.
Two failed receiver attempts exposed a fixture assumption: AppKit assigns Return
to the window's default cell without retaining a CR key equivalent on its button.
The corrected fixture verifies that actual Continue default control and invokes
its native action; this does not establish physical keyboard delivery. The build
passed with 13 recorded exit-zero diagnostic entries. Full hosted, physical and
signed acceptance remain separate.

At that repository-conflict checkpoint, standalone `WorkingTextMerge` outputs
and results rebound by Save As remained excluded. The connected saved-output
follow-up below implements that separate authority/resolve route; the earlier
checkpoint alone did not establish it. Signed sheet acceptance and every
encoding/filter and physical interaction remain separate.


## Standalone three-pane and rebound-result Resolve — October 29, 2026

The pinned writable-bottom-view eligibility also applies to a standalone merge
result; it is not restricted to the original repository conflict window. Native
three-pane results now offer Mark as resolved for standalone `WorkingTextMerge`
outputs and saved result copies. Read-only/blame and patch-result restrictions
remain. Two-pane Compare has no merged bottom view and is not made eligible.

An attempt first obtains its own unresolved-conflict affirmation, saves the
actual output, and accepts that saved baseline. It then captures an exact regular
or deleted output receipt and obtains authority for that file's actual Git
repository and any required linked metadata/object folders. The standalone
window's initial Mine-parent repository placeholder never grants staging
authority. A read-only original conflict redirected through Save As follows this
same route in the original Mark as resolved attempt, rather than becoming a
save-only operation. Selected copies capture their file identity and destination
hierarchy before the folder permission question.

The saved-file Resolve operation uses force-Add semantics separately from the
new-output AutoAdd policy. Saved bytes, mode, inode and relevant index state are
checked, unrelated staged entries are preserved, and publication is atomic.
Affirmation remains a per-attempt argument, including ignored-conflict state;
the receipt stores unresolved state without storing consent. Successful callbacks
report the actual repository root and relative output path, refreshing only
existing application owners without opening a workspace for a standalone tool.

An authority refusal, stage failure or cancellation keeps the saved editor open
with a distinct pending Resolve receipt and compact Retry Resolve control.
Unchanged clean retries—including the regular Mark as resolved action—validate
that receipt, request a fresh warning when needed, and do not save the file again.
Unsaved edits must be saved first; an accepted same-output resave advances the
receipt without automatically resolving. Result Save As rebinding retires the
old pending intent; saving another source pane does not retarget it. Repeated
commands, changed drafts, replaced owners and late callbacks cannot stage or
close a different attempt. Actual successful index publication remains success
even if cancellation arrives afterward. Deferred result EditorConfig preparation
cannot compete with the repository-authority sheet.

The [focused checkpoint](qa/merge-saved-resolve-2026-10-29.json) passed 15
distinct Core methods cumulatively, the connected System Git native cases across
the retained main run and corrected read-only recheck, and the complete current
matrix in one bundled Git run. It also passed affected Save As ownership and
AutoAdd checks with both engines. The receipt preserves each failed attempt and
separates fixture setup corrections from the encoding, callback identity and P4
provider repairs. This verifies current Debug objects, not signed candidate 28,
physical permission panels, every merge-tool layout or whole-port parity.

### Main-menu commands with P4 toolbar chrome removed

The first saved-output native checkpoint exposed a real P4 command-provider
issue: main-menu Save/Resolve and related commands reused a toolbar accessor and
dispatcher that required an attached, visible native toolbar. P4 intentionally
removes that chrome, while the editor and its main-menu commands remain live.
The menu therefore disabled Mark as resolved before its actual Save/Resolve
operation could begin; the P4 case is retained rather than excluded.

Compare, three-pane Merge and Patch main-menu factories now use the owning
provider's current model state independently of toolbar presentation. Native
menu attachment, active-window/epoch receipts, live owner/readiness checks and
per-command admission still apply. Physical toolbar and overflow controls retain
their original visibility/attachment requirements; a retained hidden toolbar
item does not gain authority from this change. The same
[checkpoint](qa/merge-saved-resolve-2026-10-29.json) exercised actual P4 Save and
Mark as resolved, Save As availability, and the existing native menu ownership
regression with hidden Compare toolbar dispatch. That older menu runner executes
System Git only for this case despite accepting two executable arguments; no
bundled run of that older menu fixture is claimed. Physical menu interaction
remains separate from these invisible native control checks.
