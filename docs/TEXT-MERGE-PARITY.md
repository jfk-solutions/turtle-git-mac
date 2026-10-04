# Text conflict editor parity

Baseline: `7338078f8ddd924b8cddee35f512f2286072136d`.
Reviewed references: CAppUtils::ConflictEdit, TortoiseMerge MainFrm.cpp save and
block-choice handlers, BottomView.cpp, and the official
[three-pane conflict guide](https://tortoisegit.org/docs/tortoisegitmerge/tmerge-dug-conflicts.html).
This is a partial port of the editor, not full TortoiseGitMerge parity.

## Native editor and dispatch

Edit conflict and conflicted-file double-clicks in Commit, Working Tree and
Resolve dispatch through one shared controller. Delete/modify conflicts and
submodules retain their dedicated native choosers. Regular UTF-8 text with both
sides opens TurtleGitMerge: Theirs on the left, Mine on the right and an editable
Merged result below. Show Base adds the original version. Native split views,
monospaced text, line numbers, green changed-source lines and red conflict blocks
support both appearances. The original Resolve and merge command artwork is reused.

Previous/Next conflict and the four block choices retain upstream meanings:
Mine, Theirs, Mine before Theirs and Theirs before Mine. The merged editor's
context menu offers the same choices only over a conflict block. Undo/Redo controls
use the editor's history. Native Find, next/previous match and Escape routing are
implemented. Save As exports the current UTF-8 result through NSSavePanel.

Normal merges display stage 2 as Mine and stage 3 as Theirs. Rebase reverses these
roles, naming the branch being replayed and the branch being rebased onto.
The index's original stage numbers remain unchanged. Add/add conflicts use an
empty base. Opening regenerates a diff3 result from captured index blobs, as
upstream regenerates from its side files. Existing working contents are captured
for save validation; they are not replaced on open. Reopening does not resume
manual edits made in a previous editor session.

## Saving and resolution

Save writes only the merged working file and retains unresolved index stages.
Saving remaining conflict markers asks for confirmation. Mark as resolved is
disabled until conflict markers are removed and saves then stages the exact path.
No action commits or continues a merge/rebase. Unsaved close asks Save, Don't Save
or Cancel. Binary/non-UTF-8 files and symlink sides are currently rejected.

Captured index stages, path containment, working bytes and permissions are checked
before writes. Atomic UTF-8 saves retain executable permissions. An index-lock
failure after saving returns a refreshed working-file snapshot and an explicit
saved-but-not-staged error, so retry can stage without discarding the result.
Read-only files require Save As. Store saves require a covering security scope;
signed sandbox behavior is still unverified.

## Evidence

The full suite passed 175 tests with zero failures. Eight TextConflict tests cover
all four block choices, multiple CRLF blocks and Unicode UTF-16 selection ranges;
real merge and add/add stage extraction; real rebase role reversal; exact UTF-8
BOM/CRLF/no-final-newline saves; executable permissions; stale working/stage/mode
rejection; binary/symlink refusal; marker checks; save without staging; exact
resolution preserving unrelated staged/working changes, HEAD, refs and MERGE_HEAD;
and locked-index save failure followed by a successful retry.

Native QA opened the actual three-pane editor with two independent conflicts.
Mine-before-Theirs replaced the first block, retained independent merged header
and footer changes and advanced to the remaining block. HEAD, index and all
working files stayed byte-identical before Save. Find opened with Command-F,
found the second block's text and closed with Escape. Choosing Theirs replaced
that second block correctly. Early keyboard Undo attempts did not restore text;
explicit history and visible Undo/Redo controls were subsequently added. The final visible Undo control restored the entire first block and cleared the
Modified indicator; Redo reapplied its combined text and restored the remaining
conflict selection. Keyboard Undo remains unverified. Native Save/Mark-as-resolved
checks are still pending. A stale selected-conflict index after Redo was observed
and corrected by recomputing selection against the current buffer.

## Remaining upstream behavior

Source panes currently display raw files, not aligned added/deleted rows with
shared scroll positions. Character-level differences, syntax coloring, whitespace
and EOL/encoding controls, folding, locator bar, source editing, complete ribbon
and menus, standalone two-file comparison, external tools, binary/image merging,
empty-result Delete/Keep, backup files, general reload/open workflows and selection
mapping from source-pane block menus remain pending. EOF block-choice fidelity
needs broader checks. Full native keyboard/Undo/Redo, save/close/export/error/rebase,
light/dark/resize and signed Finder/sandbox acceptance remain partial until verified.
