# Merge external-source reload workflow

Pinned source: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`TortoiseMerge/MainFrm.cpp::OnActivate`, `OnTimer`, `CheckForReload`,
`HasUnsavedEdits`, `DiffData.cpp::Load` and `WorkingFile.cpp::HasSourceFileChanged`
/ `StoreFileAttributes`. The prior [manual Reload continuation](COMPARE-WORKFLOW-PARITY.md)
does not implement the return-to-window workflow described here.

## Source behavior

Activation defers the check by 300 ms, allowing a pending close to run first.
The source compares existing Base, Your and Their input sizes, creation and write
times. The separate merged/output file is intentionally excluded. Missing files
and failed attribute queries do not trigger its warning. Load changes is the
default action. The warning explains that unsaved edits will be lost. Both
Ignore changes and Cancel keep the displayed versions, mark changed source panes
modified and acknowledge their current attributes. Base-only changes in a
three-pane merge do not mark the merged result modified.

## Connected native implementation

The two-file comparison and three-file conflict controllers share one owned
`MergeExternalReloadCoordinator` per document. Returning to a key window coalesces
activation into the source delay. It checks local input receipts off the main
actor; busy load/save/filter/format/Open/replacement and child-sheet operations
defer the check until their existing settlement callbacks. It does not poll the
disk on a timer or watch the entire repository. Immutable Git revisions and index
stages are not mutable source files. Rebound source panes use their accepted
Save As location. A default output that aliases Mine remains a watched input;
an independent merged-result filename does not become another watched role.

A first probe pairs attributes with accepted raw bytes, missing state and
permissions, so a rewrite between load and observer installation is detected.
Subsequent probes compare metadata, including native inode/type/permission changes
for atomic replacements. Missing inputs and failed attribute queries retain the
last observation without showing a warning; an existing input whose bytes can no
longer be verified is a change. Size/type mismatches avoid reading an unexpectedly
large replacement merely to detect that it differs. Accepted raw three-file
inputs travel with `TextConflictDocument`; they are not reconstructed by
re-encoding visible strings.

The native warning keeps Load changes, Ignore changes and Cancel in source order,
uses the owning appearance and standard warning artwork, and defaults to Load.
Load waits for actual sheet release, discards drafts without a second manual
Reload save question, reloads current files/preferences and clears document
history. Ignore and Cancel preserve draft text, annotations, selection and Undo;
their acknowledgement prevents repeating the same warning on the next activation.
A later change remains detectable.

Two-pane Keep marks eligible working-file drafts dirty without replacing their
original save baseline. Single-file mode observes only Your. Combined mode
observes both inputs but marks only the visible Your editor; revealing Base
later does not introduce a hidden forced-dirty state. Three-pane Keep records Mine/Theirs source indicators
separately from result dirtiness; Base-only changes do not dirty the result.
The native close/Open/Quit workflow can preserve retained source copies before
continuing. These native per-pane safety prompts are broader than the source's
`HasUnsavedEdits`, which does not inspect every source pane.

## Save authority and ownership

Observation acknowledgement grants no overwrite authority. Ordinary guarded
Save still rejects changed original inputs or outputs. A deliberately retained
three-file result may be saved to an independently chosen destination. That
copy rejects lexical, symlink-resolved and hard-link aliases of protected source
or original output locations, and validates the chosen target through its
existing guarded writer. A rebound independent result keeps its own subsequent
Save baseline; it must not capture a fresh baseline on every Save.

Successful own writes and Save As update affected source receipts while preserving
already acknowledged observations for other unchanged inputs. This also covers
identical-byte atomic replacements, whose new inode is an owned change. A result
write that aliases a rebound source advances that pane from the accepted write
receipt, without rereading bytes that an external editor could have replaced.
Separate result writes retain the original accepted source bytes. An explicit
accepted Reload starts a new observation baseline. Cancellation of a manual
Reload does not erase a prior Ignore acknowledgement.

Every probe captures its source identities, permissions and document generation.
Replacement/retirement cancels it and fences late results. A probe retains its
leases and global Quit count until the worker actually returns. A warning retains
its captured owner, request and count until AppKit releases its actual sheet,
even after forced retirement. Repeated replies cannot invoke another reload or
write. File/Open rebinds future checks to the adopted native frame while the old
request drains. If Quit or another owned operation blocks a reply at actual
sheet release, the change is requeued without acknowledging unseen content.
No file is read or rewritten merely because an unrelated frame activates.

## Validation and remaining work

The Debug app and 59 distinct focused Core methods passed; only the extended
accepted-write method was repeated after its Core repair. The new activation
case passed with system and bundled Git. It covers actual hidden warning sheets,
the native default button and owning dark appearance, dirty Load, Ignore/Cancel,
Save As and equal-byte owned replacements, Single/combined policies, retained
source copies, File/Open frame adoption and forced-close lease/Quit drain.
The directly affected manual Reload and existing two-/three-file entry workflows
also passed with both Git engines: eight distinct native case/engine pairs total. [Dated QA evidence](qa/merge-external-reload-2026-10-18.json)
retains the actual earlier failures and fixture repairs; authored assertions alone
are not passing evidence.

Physical application activation/restoration, every filesystem's metadata policy,
network volumes, full native input/accessibility and installed signed App Store
permissions remain separate acceptance. A scoped local pass cannot establish
complete TortoiseMerge parity or a current full hosted integration pass.
