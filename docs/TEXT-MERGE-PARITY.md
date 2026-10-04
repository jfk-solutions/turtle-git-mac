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
monospaced text, original source line numbers and aligned read-only source rows
support both appearances. Removed base rows use upstream orange, additions yellow,
conflicts red and alignment gaps gray, with upstream dark variants. Removed rows
and gaps have no source number and never enter the editable merged result. The original upstream ribbon artwork is reused for Save, Save As, Mark as
resolved, Undo/Redo, Find, conflict navigation and all four block choices. Twelve
unchanged BMP assets carry source/blob/SHA-256 provenance. The ribbon XML command
mappings were reviewed. AppKit ignores BI_RGB BMP alpha by default; the native
renderer reads their original straight BGRA pixels explicitly, preserving
transparency and orientation. Icon tests check transparent corners and visible
pixels, and actual light/dark captures verify contrast without black backgrounds.

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

The full suite passed 180 tests with zero failures. Eight TextConflict tests cover
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
conflict selection. Manual Unicode edits and visible Undo were subsequently verified. Command-Z
still left the edited text unchanged in native QA, while Command-F opened Find.
Two local event-monitor routing experiments did not correct this and were removed.
Keyboard Undo remains a known defect. Native Save wrote the exact combined first block and Theirs second block while
retaining all three index conflict stages. Mark as resolved then staged those
exact reviewed bytes and cleared all unmerged entries. Both operations preserved
HEAD, refs, unrelated index/working changes and MERGE_HEAD. A stale selected-conflict index after Redo was observed
and corrected by recomputing selection against the current buffer.

## Remaining upstream behavior

The source alignment is a Swift exact-byte line comparison, not the upstream
libsvn diff3 engine. Exact segmentation of complex/repeated/adjacent changes still
requires comparison against that engine. Synchronized vertical source scrolling
is implemented, but native attempts encountered inaccessible scroll targets and
no-window observations; it remains unverified. Character-level differences, syntax coloring, whitespace
and EOL/encoding controls, folding, locator bar, source editing, complete ribbon
and menus, standalone two-file comparison, external tools, binary/image merging,
empty-result Delete/Keep, backup files, general reload/open workflows and selection
mapping from source-pane block menus remain pending. EOF block-choice fidelity
needs broader checks. Full native keyboard/Undo/Redo, save/close/export/error/rebase,
resize and signed Finder/sandbox acceptance remain partial until verified.

Actual light/dark captures are site/assets/text-merge.png and text-merge-dark.png,
both 2240 × 1624 pixels, showing the aligned source rows and upstream palette. Native capture QA preserved HEAD, index and every working
file. The initial capture exposed a scrolled line number drawing into the pane
heading; converting text coordinates into ruler coordinates and clipping its
visible area corrected it in both verified captures. The upstream three-pane
screenshot was visually inspected: pane order matches. Aligned source rows and richer color distinctions have now
been added; exact diff3 segmentation, locator strip and full toolbar remain outstanding. Show Base subsequently worked in the current native dark build and displayed
the exact original contents alongside both sides. A manual-edit/close-cancellation
check encountered AX selection/observation failures and remains unverified.

## Aligned source evidence

Reviewed DiffData.cpp's three-way common, identical-change, one-side-change and
conflict row construction; DiffColors.h defaults and DiffColors.cpp palette
initialization; and BaseView.cpp inline-diff gating. Five new tests verify
unequal changes, independent/shared additions and deletions, source numbering,
empty files, no final newline, CRLF and exact NFC/NFD byte distinctions. They
reconstruct both sources across 3,375 exhaustive small-file combinations and
500 seeded longer Unicode/CRLF combinations. These invariants establish source
preservation, not complete libsvn segmentation parity.

Actual native light/dark captures verify orange removed rows, yellow added rows,
red conflicts and gray gaps with the original ribbon icons. The initial editor
now opens at 1120 × 780 rather than being reduced to its minimum by hosting
layout. The merged buffer retains Git's original diff3 text. Find keeps its
source editor target while the search field is focused; broader keyboard QA is
still pending.
