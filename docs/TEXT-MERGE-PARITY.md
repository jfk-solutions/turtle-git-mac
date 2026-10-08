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

## Line-ending submenu and CRLF marker guard

The merged result context menu now has Line endings → CRLF, LF, CR, LFCR, VT,
FF, NEL, LS and PS, in the order and with labels reviewed in EOL.h/EOL.cpp and
BaseView.cpp. A uniform current style is checked; mixed text has no checked item.
Conversion changes existing terminators only, preserving Unicode spelling, BOM
and missing final newline. It is disabled while busy and records one Undo step.
Source panes remain read-only. Default endings for newly typed lines, encoding
controls and full upstream view metadata remain pending.

Conflict parsing, unresolved-marker detection and the caret caption share a
UTF-16 scanner for all nine endings. This fixes a CRLF safety defect: Swift treats
CRLF as one Character, so the previous character split could miss a conflict
marker after ordinary introductory text. Incomplete opening/base/closing markers
still block resolution; a standalone equals heading does not. FileTextLines.cpp's
LF-before-CRLF heuristic is retained to avoid consuming the next line's CR.

Four scanner tests cover 162 conversions, mixed endings, Unicode/BOM/EOF, all
nine prefixed conflict forms and UTF-16 caret positions. Ten real-Git conflict
tests also reject unresolved EOF results before staging. All 14 targeted tests
passed, and the app compiled. The full suite passed 186 tests with zero
failures before the final combined-choice correction. Combined choices now
retain existing terminators for all nine styles, including mixed-style blocks;
a separator is inserted only when original EOF metadata removed one. The final
targeted regression result is recorded below.

Native QA in /private/tmp/TurtleGitMergeCRLFMarkerQA verified the nine menu
choices, initial CRLF state, CRLF → LF, one-step Undo/Redo, restored clean state,
line 2 after the CRLF introduction, disabled Mark as resolved, and Save warning
followed by Cancel. HEAD, refs, unresolved index and working-file bytes matched
the baseline exactly. Exotic ending native conversion/save combinations and
mixed-style native menu checks remain pending. The QA instance was closed
after verification.

After the combined-choice correction, all 14 targeted tests passed again.
After adding all 81 mixed-style pairs in both orders, the four scanner tests
passed again. The full-suite run preceding that correction passed 186 tests.

## Whitespace commands

BaseView.cpp's ConvertTabToSpaces, Tabularize, RemoveTrailWhiteChars and
GetWhitecharsProperties were compared with the native merged-result menu.
The resource labels Convert tabs to spaces, Convert spaces to tabs and Trim
right are retained, before the line-ending submenu. Each command transforms
the full merged result and uses one Undo step. Source panes remain read-only;
busy or inapplicable commands are disabled and guarded again on dispatch.

Both conversions touch leading ASCII spaces/tabs only. Tabs within text remain
unchanged. Expansion uses the next four-column stop; tabularization retains
partial runs and follows the upstream handling of existing tabs. The native
paragraph tab interval now matches four monospaced columns in all panes. Trim
right removes trailing ASCII spaces/tabs. Global tab-width preferences, EditorConfig,
locale-specific Unicode TrimRight behavior and visual tab-width acceptance
remain pending. Original line terminators and Unicode spelling are preserved;
whitespace-only final lines may naturally become empty after trimming.

Three new tests cover all nine endings, mixed terminators, leading tab stops,
partial runs, trailing whitespace, internal tabs, Unicode/NFD, BOM, blank lines,
missing final newlines and availability. All 17 targeted scanner, whitespace
and text-conflict tests passed with zero failures; the app also compiled.

Native QA entered a Unicode/NFD draft with CRLF and no final newline, exercised
leading-tabs expansion and one-step Undo, then spaces-to-tabs and Trim right.
The spaces-to-tabs command became disabled after normalization. Save produced
exactly `\t  🦎é\t雪\r\n\t tail\r\n\tEOF`, preserving HEAD, refs and
unresolved index stages. The QA app was closed immediately afterward, with no
preview processes remaining. Busy-state and large-file native QA remain pending.

## Per-pane tab widths

MainFrm.cpp's FillTabModeButton, OnTabMode and OnUpdateTabMode were reviewed,
along with BaseView's width accessors and SetMainPage's default width four.
Each native pane now has a footer width menu with the upstream 1, 2, 4 and 8
choices, a checkmark for its current width and Tab N caption. Changes are local
to that pane and editor session, refreshing its monospaced tab interval without
changing text, dirty state or Undo history. The merged pane's whitespace
conversion and availability use its selected width. Global preference persistence,
Global insertion-mode preferences and EditorConfig remain pending.

Regression checks now cover all four menu widths, leading tab stops and
internal-tab preservation. All 17 targeted merge tests passed and the app
compiled. Native QA independently selected Mine 2 and Merged 8 while Theirs
retained 4; the result remained clean with Undo disabled. An eight-column
conversion preserved internal tabs, Unicode/NFD, CRLF and no final newline;
Save wrote the exact expected bytes without changing HEAD, refs or unresolved
index stages. The spaces-to-tabs item was disabled for a four-space run at
width eight. The QA app was closed and no preview instances remained running.
Pixel-level tab alignment in all four panes, resize and broader menu QA remain
pending.

## Tab, Space and Smart tab char

Per-pane menus now retain upstream Tab, Space, Smart tab char and the width
choices, with Tab/Space N Smart captions. Mode changes alter session-local
behavior without rewriting text. The merged NSTextView dispatches Tab through
the reviewed BaseView GetIndentCharsForLine rule: explicit Space inserts to
the next expanded UTF-16 tab stop; explicit Tab inserts one tab. Smart mode
uses any tab in the current line, otherwise a space streak greater than the
width, then searches up to 100 lines on each side. A nearby tab wins; space
evidence requires both lines at the same distance; undecided Smart falls back
to tabs even when explicit Space is selected.

A multiline selection uses the reviewed Add/RemoveIndentationForSelectedBlock
rules. Tab skips empty/whitespace-only lines, adds a mode-dependent prefix,
and excludes the final line when selection ends at its start. Shift-Tab removes
up to one width of leading spaces, or a tab after a shorter space prefix. Each
block change records one Undo step and retains a selection over the affected
lines. Single-line insertion replaces selected text first when computing the
indentation mode, matching upstream OnChar ordering. Global preferences,
EditorConfig, precise partial-column selection restoration and broader key/view
behavior remain pending. Unicode whitespace-only classification uses Foundation
and still needs comparison with upstream's locale-sensitive trimming.

Three new tests cover explicit modes, UTF-16/expanded columns, all nine endings,
current/nearby Smart evidence, 100/101-line boundaries, block indentation, blank
lines, mixed leading spaces/tabs, end-boundary exclusion and invalid ranges.
All 20 targeted merge tests passed and the app compiled. The whitespace tests
were rerun after tightening the invalid-range guard.

Native QA verified Space Tab at column two, single Undo, Space 4 Smart choosing
a tab from the preceding line, disabling Smart, multiline Tab/Shift-Tab and
one-step Undo of unindent. Save produced exactly four leading spaces on each
nonblank selected line with the two-space blank line intact, CRLF separators
and no final newline. HEAD, refs and unresolved index remained unchanged.
The QA app was closed immediately; no preview instances remained running.
Other Smart branch native combinations, partial-column selections, readonly
keyboard handoffs and signed/sandbox acceptance remain pending.

## Saved indentation defaults in native Settings

Native Settings now has Appearance and Merge Editor tabs. The partial General
section maps IDD_SETMAINPAGE's Use spaces, Smart tab char and Tab size, with
Apply and Cancel. Defaults are Tab, Smart off and width four. MainFrm.h's
1–1000 range is used for validation and stored-value clamping. Apply saves
defaults and refreshes open panes without editing text or clearing Undo history;
Cancel discards the draft and closes Settings. Session menus can still override
each pane, including false overrides when global defaults are enabled.

The native approach preserves the editable result when indentation defaults
change. Upstream settings can request LoadViews and a Save check; that broader
reload behavior, other General options, Colors, EditorConfig and full Settings
parity remain pending.

An isolated UserDefaults test covers fresh defaults, saved non-menu width seven,
booleans, a second defaults instance, invalid stored values and write clamping.
All 21 targeted tests passed; the final Cancel/window implementation compiled.
Native QA rejected zero with Apply disabled, discarded it through Cancel,
reopened with four, applied Space/Smart/seven, and observed Space 7 Smart on all
three open panes while the result remained clean and Undo disabled. Quitting and
relaunching restored all three captions. Working bytes, HEAD, refs and unresolved
index matched their pre-test state. The QA app was closed immediately after
verification. False session overrides, active Undo preservation, upper-bound
native checks, resize/dark and signed/sandbox acceptance remain unverified.

## Show line numbers

IDD_SETMAINPAGE's Show line numbers control now saves a default-on preference
and updates the AppKit rulers in Theirs, Mine, Base and Merged. Older saved
indentation preferences without the new key retain the upstream default. A
line-number-only Apply preserves per-pane tab overrides and the editable result's
Undo history; indentation-default changes still reset their relevant overrides.

The isolated preferences test now covers false persistence and missing-key
migration. All 21 targeted tests passed with zero failures; the app compiled.
Native QA selected a merged width-eight override, displayed Base, inserted a
reversible tab, then applied line numbers off. A native screenshot verified no
rulers in all four panes, width eight retained and Undo available. Undo restored
the draft, Apply on restored the rulers, and the earlier draft edit could still
be undone to the original clean result. Working bytes, HEAD, refs and unresolved
index remained unchanged. The QA app was closed immediately after verification.
Line-number-specific relaunch, long-file scrolling, dark/resize and signed/sandbox
acceptance remain unverified. App-wide Quit is covered separately below.


## Application Quit with unsaved merge results

The native application delegate now defers termination when merge windows have
unsaved results. Each dirty result offers Save, Don’t Save and Cancel. Save waits
for the existing guarded asynchronous working-file write; a cancelled marker
warning or failed write cancels termination. All open merge editors are frozen
while the decision is pending, including source-file replacement and keyboard
Undo. Cancel restores editing. Quit is rejected while the repository model or a
merge editor reports an operation in progress.

This addresses a reproduced bug: the previous app exited on Command-Q without
asking about a modified merge result. Upstream MainFrm.cpp's OnClose save check
is the behavior reference; the macOS implementation handles application-wide
termination as well as the existing per-window close check.

Native acceptance used one disposable QA instance at a time. Cancel retained the
draft and Undo history, and a second Quit displayed the choices again. A stale
working-file Save rejected the write, displayed the error and retained the draft.
After restoring the disposable baseline, Save on Quit wrote exact UTF-8 bytes
with NFD text, CRLF and no final newline, then exited; HEAD, refs and unresolved
index stages stayed unchanged. Don’t Save exited while retaining the previously
saved working file. Process checks confirmed each instance exited; none was left
running. The UI observer temporarily retained a stale application-menu snapshot
during the successful Save retry; process and exact-byte checks proved that Save
completed, and the next launch provided direct dialog observations for Cancel
and Don’t Save. The 21 merge tests and 10 rebase tests passed with zero failures;
the latter include real Git operations using the actual application executable
as the headless sequence/message editor after the new delegate was added.

Multiple dirty windows, Quit during a deliberately long operation, nested marker
warning cancellation and signed/sandbox termination remain acceptance work.
Other dialog models' operations and unsaved drafts need their own Quit audit;
this change does not establish application-wide parity for those dialogs.

## Unicode input and File Encoding output

The three-pane editor now decodes the supported Unicode formats for Base, Mine,
Theirs and the working snapshot before generating a UTF-8 temporary merge.
BOMs are file metadata and do not enter the source strings or conflict markers.
The result initially uses the working file's detected encoding, falling back
to Mine when the working file is absent. Its File Encoding menu mirrors the
two-pane choices: UTF-8 and UTF-16LE/BE with optional BOMs, UTF-32LE/BE with
BOMs, and explicit Windows-1252. Upstream `FileTextLines.cpp:489–537` supplies
the output/BOM rules; `BaseView.cpp:6078–6087` marks a changed format modified.

Encoding-only changes count as dirty for close, reload and application Quit.
Save, Save As and Mark as resolved use the selected format. Conversion rejects
unrepresentable text before changing the choice or writing bytes. Save As
balances the selected URL's security scope. A shared codec correction preserves
a literal leading U+FEFF after removing only the format's header BOM.

Native acceptance opened a conflict with a UTF-16LE/BOM working file and Chinese
text plus an emoji. Use Mine whole file retained CRLF and missing final newline.
Windows-1252 rejection retained the draft; UTF-32LE Save wrote exactly 64 bytes
and retained 0755 while leaving the raw index unchanged. A format-only UTF-8 BOM
change triggered the close prompt, and Cancel kept it. Save As wrote an exact
23-byte export without changing the working file; Mark as resolved then saved
and staged those 23 bytes with executable mode. HEAD, MERGE_HEAD and unrelated
staged/working files were preserved. The sole QA app quit normally and process
absence was verified. See [record](qa/conflict-encoding-2026-10-05.json).

Real-Git regressions exercise mixed UTF-16LE/UTF-8/UTF-32 stage encodings, every
output format, no BOM leakage, lossless rejection, modes, index preservation,
resolution and leading U+FEFF text. All 355 tests, both builds, both bundle/runtime
audits and the documentation site build passed. The existing stale-stage, stale-working-file,
marker and failed-stage-retry checks continue to apply.

Full Windows ANSI code-page/input selection, ambiguous BOM-less Unicode,
remaining native format/checkmark variants, Save-and-Reload/Quit encoding
variants, source editing and signed sandbox acceptance remain pending. This
is partial TortoiseMerge encoding parity.

## Pane format status controls

Upstream `BaseView.cpp:269–430` places encoding, EOL and tab mode in each pane's
status ribbon. TurtleGit now shows original source encodings and current draft
ending styles in both comparison and conflict panes. Writable panes provide
encoding and EOL menus with checkmarks; read-only panes report their formats.
The comparison byte count is explicitly labeled saved bytes, because a draft's
output format can change before Save. Conflict documents retain Base/Mine/Theirs
encoding metadata across result saves. Ending changes use existing Undo paths.

Native acceptance verified distinct UTF-32BE, UTF-8 BOM and UTF-16LE BOM source
indicators, CRLF/LF conversion with Undo, result encoding changes/checkmarks,
and two-pane footer behavior. Loaded mixed-ending and single-line files show
Mixed EOL and No line ending. Source files and repository bytes remained
unchanged by the UI. The twelve conflict tests and both builds/bundle audits
passed. The actual light-window screenshot is published; all QA processes were
closed. See [record](qa/format-status-2026-10-05.json).

Dark/narrow layout, remaining native formats, absent/binary sources, upstream
read-only-source format interaction, insertion defaults and signed sandbox
acceptance still need work. Mixed-ending paste normalization is existing editor
behavior; this change does not establish paste or full status/view parity.

The tab footer now uses a shared `MergeTabControls` component with two-pane
comparisons. Its Tab/Space, Smart and 1/2/4/8 choices are retained; the label now
includes current settings for accessibility. Native re-acceptance of this
refactored three-pane menu remains pending. See
[comparison tab acceptance](qa/comparison-tabs-2026-10-05.json).

## Nine-style source alignment

Mine/Theirs read-only alignment now uses the shared FileTextLines boundary
recognition for CRLF, LF, CR, LFCR, VT, FF, NEL, LS and PS. Each numbered cell
retains its exact source text and ending; removed Base rows and gap rows remain
display-only. The native source panes render one LF per display row, with original
source numbering and linked scrolling. Source ending differences still count as
changes; alignment does not silently normalize stage text.

[Three-pane endings QA](qa/three-pane-endings-2026-10-08.json) records 41 focused
Core tests, including 729 Base/Mine/Theirs style combinations, and native checks
against four Git versions. Each native run creates nine real unmerged source
pairs and loads the production three-pane controllers. It checks exact stage
text, unequal conflict-side/gap numbering, read-only display and rulers, linked
scrolling, and unchanged HEAD/raw index/conflicted working bytes. All owned
hidden windows close after testing; the main application is not launched.

This verifies source alignment and display. Physical keyboard/menu interaction,
full source merge-engine equivalence, exhaustive mixed-ending/selection cases,
final-empty-row behavior, and signed sandbox acceptance remain pending. The
existing result conflict parser and save paths are separate from this change.
