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
resolved, Undo/Redo, Find, conflict navigation and all four block choices. Thirteen
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

The full suite passed 182 tests with zero failures. Ten TextConflict tests cover
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
conflict selection. Manual Unicode edits and visible Undo were subsequently verified. The apparent
keyboard failure was traced to the QA host's keyboard layout: the automation
key named `y` visibly inserts `z`. In the production build without event monitors,
logical Command-Z restored the original text and cleared Modified; logical
Shift-Command-Z restored the inserted character and Modified. Earlier calls named
`super+z` did not test logical Command-Z on this host. The unsuccessful local
monitor experiments were removed. Unicode keyboard history, search-field history
and broader keyboard combinations still need acceptance checks.
 Native Save wrote the exact combined first block and Theirs second block while
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
empty-result Delete/Keep, backup files, complete reload/open workflows and selection
mapping from source-pane block menus remain pending. EOF block choices now use original source ending metadata for the unchanged
final conflict; broader edited-marker and encoding combinations need checks. Full native keyboard/Undo/Redo, save/close/export/error/rebase,
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

## Conflict menu validation

AppKit automatically validates contextual menus. Explicit item enabled flags
can be overwritten; see Apple's [menu validation guidance](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/MenuList/Articles/EnablingMenuItems.html).
The merged text view now validates its four block actions against editability,
busy state, action tag and a current conflict at the selection. Standard text
actions retain NSTextView validation. The action handler repeats the busy/editable
checks. Native context-menu QA verified all four block commands disabled outside
a conflict. Inside-conflict activation, busy-state UI and multi-block selections
remain pending.

## Whole-source file and Reload

LeftView.cpp and RightView.cpp offer “Use this whole file” in each source pane
when a three-pane result exists. BaseView.cpp routes these commands to the bottom
view; BottomView.cpp replaces the result using the source file's lines. Native
Mine/Theirs context menus now expose that command with original side artwork.
They copy the original captured stage text, excluding display-only removed rows
and gaps, and replace the entire result as one undoable edit. Rebase uses the
already-reversed Mine/Theirs document roles. Save and resolution remain separate.
The current implementation retains exact UTF-8/EOL/EOF source contents; upstream
result-EOL normalization and source-pane state changes are not yet reproduced.

Native QA verified Mine replaced the entire result, including its title and
ending line 5, excluding the incoming footer and display-only Base rows. Both
conflicts disappeared and Mark as resolved became available. Logical Command-Z
restored the full original diff3 result, both conflicts and the clean indicator;
logical Shift-Command-Z restored Mine and Modified. Escape displayed the unsaved
close prompt; Cancel retained Mine. Native Theirs in the final dark build also replaced the complete result with
its Base title, both Theirs values and incoming footer, omitting ending line 5.
No-final-newline, rebase and Save after whole-source selection still need native
checks. Existing core tests cover exact
stage extraction and UTF-8/CRLF/EOF save preservation, but do not prove those UI
combinations.

Reload is now visible with the unchanged upstream Refresh.bmp ribbon artwork
and SHA-256 provenance. Dirty results now offer Save and Reload, Reload Without Saving and Cancel. A successful reload
recaptures current stages and working-file guards, regenerates the merge and
source alignment, and clears old Undo/Redo actions. Failures retain the prior
result and history. The Save and Reload path uses the existing guarded save and then reloads under
one busy operation; a save failure stops reload. The replacement document and
alignment are prepared before clearing history or publishing the new view.
Native dirty Reload displayed Cancel/Reload in the final dark build; Cancel
retained Theirs, Modified and enabled Undo. Confirmed Reload/history-reset checks
encountered missing-window observations and remain unverified.

Opening the Mine context menu moved both source vertical scrollbars from 0 to 1,
providing native evidence of coupled source positions. Direct wheel/scrollbar
movement, intermediate positions and resize behavior remain unverified. The
previous 2240 × 1624 captures predate the new Reload control and source menu.
The original icon pixel test now includes Refresh.bmp and passes. The full suite
passed 180 tests with zero failures, followed by a successful final app build.

Dirty detection and text-view refresh compare UTF-8 bytes rather than Swift's
canonical String equality, so visually equivalent NFC/NFD changes remain
unsaved edits and can refresh the displayed buffer. Native normalization-only
edit/close acceptance still needs verification.

## Save before Reload

Reviewed MainFrm.cpp::CheckForSave's three-way path, Reload reason and failure
return: Save, discard and Cancel are available, and failed Save cancels Reload.
The native prompt now offers Save and Reload, Reload Without Saving and Cancel.
Unresolved-marker Save confirmation and stale-file/index/permission validation
still apply. Busy remains active throughout save and reload. Reload failures
retain the current result/history; if Save succeeded first, the refreshed saved
snapshot remains available for retry. Successful reload clears old history,
selection requests and caret state before selecting the regenerated conflict.

Nine targeted TextConflict tests pass. The added real-Git save/reload test stores
a Unicode/NFD/CRLF/no-final-newline draft, regenerates the original diff3 conflicts
and captures the saved working bytes without changing index stages, HEAD, refs,
MERGE_HEAD or unrelated index/working contents. This covers the backend sequence,
not the native alert or history-reset rendering.

Native QA in /private/tmp/TurtleGitMergeReloadQA selected whole Mine, displayed
all three prompt choices and clicked Save and Reload. The working file then
matched the original Mine-stage bytes exactly. HEAD, refs, all unresolved index
stages and unrelated notes.txt stayed unchanged. Subsequent window observations
timed out, so final regenerated view/history state and Reload Without Saving
remain unverified in this build. The earlier Cancel verification used the prior
two-choice prompt; the new prompt's Cancel still needs native acceptance.

The final full suite passed 181 tests with zero failures, including the new save-before-reload regression.

## End-of-file block choices

Git merge-file inserts a line ending before conflict markers even when a source
ends without one. The native editor now passes the original document to conflict
parsing. For an unchanged original final conflict, source byte suffixes determine
whether that delimiter was artificial. Single-side choices retain original EOF
behavior; combined choices add a separator between sides and retain the final
side's EOF. CRLF marker delimiters and a source's literal trailing CR are handled
separately. Checks use UTF-8 bytes, avoiding Swift's CRLF grapheme behavior and
canonical Unicode equality. The generated conflict result is retained separately
from the saved clean baseline, so Save → Undo → reselect keeps the same metadata.

This is conservative: trailing context or modified conflict sections disable
EOF correction. It does not establish complete upstream result-EOL normalization,
source-line mapping or arbitrary manually edited-marker parity. BottomView.cpp's
UseBlock/UseBothBlocks and BaseView.cpp's nonlast-line EOL handling were reviewed.

A real-Git regression covers five source-ending combinations, all four choices,
Unicode/NFD, CRLF, a literal trailing CR, trailing manual context, edited blocks,
Save → Undo/reselect and Save/Mark as resolved byte results. Choice calculation
preserves the working file and index; Save retains unresolved stages; resolution
keeps HEAD, refs and MERGE_HEAD unchanged.

Native QA in /private/tmp/TurtleGitMergeEOFQA applied Mine before Theirs and Save.
Disk bytes were exactly `common\nMine é\nTheirs 雪`, with a delimiter between sides
and no final newline. NFD spelling, HEAD, refs and unresolved index were preserved.
Further native resolution/Undo observations timed out; those EOF-specific paths
and native CRLF acceptance remain unverified.

The 182-test suite passed; after the generated-result metadata retention change,
all 10 TextConflict tests passed again and the app compiled successfully.
