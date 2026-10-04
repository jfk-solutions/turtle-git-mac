# Submodule Diff and Changed Files parity

Status: partial native port, not full FileDiffDlg or TortoiseMerge parity.

The source reference is pinned to `7338078f8ddd924b8cddee35f512f2286072136d`:
[SubmoduleDiffDlg.cpp](https://github.com/TortoiseGit/TortoiseGit/blob/7338078f8ddd924b8cddee35f512f2286072136d/src/TortoiseProc/SubmoduleDiffDlg.cpp)
(blob `2cf3e4174776d769bfb46a6caa0d44fea23cdca2`) and
[FileDiffDlg.cpp](https://github.com/TortoiseGit/TortoiseGit/blob/7338078f8ddd924b8cddee35f512f2286072136d/src/TortoiseProc/FileDiffDlg.cpp)
(blob `fe4171a852023344cac5af1711873104393e1b0a`). Both downloaded blobs were
verified. Resource references are `IDD_DIFFSUBMODULE` and `IDD_DIFFFILES`.

## Existing comparison metadata backend

`SubmoduleComparison.swift` resolves the superproject's From gitlink and either
its historical To gitlink or the actual initialized child checkout's HEAD.
An uninitialized working checkout retains the indexed gitlink as its displayed
revision. It reports subjects, metadata availability, dirty state and the
upstream change categories: identical, addition, deletion, fast-forward,
rewind, or newer/older/equal commit time for divergent histories. Missing child
objects and uninitialized checkouts produce Unknown with unavailable Log sides.
An absent side has no Log revision. Historical comparisons ignore current
checkout dirtiness. Working comparisons include staged, unstaged and untracked
changes, while ignored files do not make the checkout dirty.

Paths and revisions are literal arguments. Tree records use NUL delimiters and
exact path matches, preserving Unicode, commas, newlines and pathspec-looking
names. Child checkout roots are verified before metadata access; external
checkout symlinks and escaping parents are rejected. A conflicted index is rejected instead of presenting stage zero as
resolved; explicit Diff-to-conflict-window routing still needs acceptance. Reads do not publish index updates or change HEAD/working contents.

Seven existing real-Git metadata tests cover the change categories, dirty and
ignored files, historical comparisons, missing objects, uninitialized modules,
unsafe paths and retained Revert baselines.

## Native implementation

Submodule Diff groups From and To revisions and subjects, with a separate Log
button for each side. The To group labels the working tree when appropriate.
The type colors match the upstream RGB values; a dirty checkout uses red text
on yellow. Missing metadata disables comparisons and highlights the subject.
Update opens the existing Submodule Update window with that path selected.
Identical revisions open child repository status; otherwise Show diff compares
the two child commits. The dirty comparison menu also offers Compare against
the working tree. F5 refreshes the metadata in place.

Changed Files has two revision groups, a path filter, five columns (File,
Extension, Action, Lines added, Lines deleted), whitespace options, Common
ancestor, Log, Swap and View Patch. Double-click and Compare revisions open a
native two-pane file viewer; unified diff remains a separate context action.
The colored patch viewer operates in read-only mode. Empty selections clear the patch.
Patch refresh errors remain visible; reloading the comparison invalidates old
patch requests without leaving the patch window busy. Patch placement is
constrained to the parent screen's visible frame.

The core resolves commit names to immutable object IDs before constructing a
snapshot. Rename paths and filenames containing Unicode, newlines or pathspec
syntax are parsed with NUL records and passed literally. Comparisons against
the working tree include staged and unstaged tracked changes. Untracked files
are excluded until added to Git. Empty-tree comparisons support added/deleted
submodules. Reverse comparison uses Git's `-R`. Whitespace-only entries omitted by Git numstat are now hidden, matching the
upstream FileDiff filter. Binary entries and gitlinks remain visible.

Successful Revert retains the operation's exact comparison revision and its
restored submodule paths. Its Handle submodules button closes progress and
opens their Submodule Diff windows. Commit-driven Revert does not auto-close
this post-action when the result contains submodules. Failed or cancelled
Revert does not offer the post-action.

Selecting an indexed submodule directory for Diff resolves its containing
repository; a file inside it still resolves the child repository. Multiple
native windows share the same application process. Busy comparison and patch
reads participate in application Quit coordination.

## Evidence

Four real-Git comparison tests cover immutable refs after HEAD advances,
rename/binary/literal filenames, repository and selection rejection, staged
and unstaged working changes, reverse and empty-tree comparisons, whitespace,
divergent common-ancestor behavior and unchanged index/HEAD/working bytes.
Submodule ownership coverage includes a newline/pathspec-like directory.

Native QA used an owned disposable parent/child fixture. Finder Diff displayed
Fast Forward and the dirty marker. Show diff listed the committed child change;
its selected read-only patch showed `child base` to `child next`. After Revert,
Handle submodules opened the captured base. Compare showed `child base` to
`local working change`, with Swap disabled. Parent/child HEAD and index bytes
were unchanged by comparison; post-Revert preserved the child index and dirty
file. Each QA process was quit and process absence verified before another
launch. Closing the patch produced an accessibility observation timeout; a
process sample showed an idle AppKit event loop, and normal Quit succeeded.
This remains a UI-observation limitation to investigate.

The gallery contains inspected, unedited actual light-mode captures:
`submodule-diff.png` and `changed-files.png`.

## Remaining work

Full reference-browser tree/context behavior, upstream Log range behavior,
the remaining file context actions need porting. Native
complete two-pane editing/save workflows, image-diff controls,
alternative diff tools, blame, export and restore integration remain pending.
Conflicted gitlinks retain the existing conflict workflow and need explicit
Diff routing acceptance. Shift-alternative comparison is not wired. Dedicated
native tests for identical/missing/historical states, Log and Update handoffs,
F5, filter/swap/whitespace controls, multi-monitor placement and busy
Quit remain. Signed Finder and sandbox security-scope acceptance are pending.
These source files and dialogs remain partial in the full-port scope.

## Two-file comparison follow-up

`FileComparison.swift` reads exact blob bytes from the snapshot's immutable
commits. Added/deleted files have an empty opposite side; renamed files use the
old base path. Literal NUL-delimited tree lookup preserves unusual filenames.
Working comparisons read the working file rather than the index, and symlinks
display their target text without following the final link. Binary data is
retained; UTF-8 (with optional BOM) and BOM-marked UTF-16 are decoded explicitly.
Line alignment retains original line numbers and detects byte-distinct Unicode,
line endings and missing final newlines.

The native Base/Theirs split view uses the existing original artwork and
light/dark merge palette: removed, added and alignment-gap rows. It provides
synchronized vertical scrolling, previous/next difference, native Find, line
numbers and F5 Reload. Historical sides remain pinned when reloaded. Recognized
images have a side-by-side preview; other binary/unsupported text encodings show
byte counts and a bounded hexadecimal preview. Gitlinks route to Submodule Diff,
including empty sides and a reversed working-checkout comparison.

Three core tests cover alignment recovery, historical rename/add/delete/binary/
symlink bytes, pinned commits, working vs staged content, reversed comparisons,
UTF-16 and unchanged index bytes. A separate submodule test covers empty sides
and reversed working checkout. One native QA instance verified added/deleted
file double-click, empty opposite panes, difference navigation, Find (12 hits)
and line-number toggling. Its actual dark capture is `two-file-diff-dark.png`.
Normal Quit exited the process; parent/child HEAD, indexes and local text were
verified unchanged. Long-file scroll synchronization, multiple difference
navigation, native rename/binary/image cases, light capture and signed sandbox
acceptance remain unverified. Historical comparisons remain read-only; full TortoiseMerge
editing, encoding selection, word diff, locator, folding and settings remain
part of the unfinished full port.

Validation for this follow-up: all 243 integration tests passed. Final unsigned
Xcode Debug and App Store builds passed, followed by both bundle audits. The
App Store audit exercised the universal Git 2.55.0 runtime's local commands and
verified its 11 Mach-O files, embedded Finder extension, licenses and 60 original
icon resources. The static Pages build passed. These checks do not prove signed
Finder activation, signed sandbox behavior or App Store approval.

## Working-file editing follow-up

`FileComparisonEditing.swift` maps AppKit UTF-16 selections in aligned panes
back to real source text. Display gaps and synthetic final newlines are excluded
from saved bytes. Existing CRLF endings and missing final newlines survive edits;
inserted newlines use the file's CRLF/LF convention. The viewer offers explicit
Enable editing for an existing regular working file on either comparison side,
Save with the original artwork and Command-S, plus guarded close and Reload.
Historical blobs, symlinks and unsupported encodings remain read-only. Binary
and image comparisons retain their inspection workflow.

Save preserves UTF-8 BOM or BOM-marked UTF-16 endianness and POSIX permissions.
It rejects changed file bytes, changed permissions, replacement symlinks and
read-only destinations, writes a sibling temporary file, revalidates the target
and atomically replaces it. It never stages, commits or publishes an index.
Close offers Save/Don't Save/Cancel; Reload offers Save and Reload/Reload Without
Saving/Cancel. Parent Changed Files closure sends dirty children through their
close guard. Application Quit includes dirty two-file results in its existing
coordinated save flow and blocks new edits while confirmation is pending.

Three new tests cover gap selection, CRLF edits, EOF, source/display caret
mapping, BOM encodings, preserved executable permissions, reversed working-side
Save, stale bytes/permissions, read-only files, replacement symlinks and unchanged
HEAD/index. Native QA caught rapid typing reusing the previous alignment; the
edit handler now updates text and caret synchronously before the next key event.
The corrected build saved all typed characters and exact no-final-newline bytes.
Parent and child HEAD/index bytes stayed unchanged. Close Cancel retained a
draft; Reload Without Saving restored the previously saved file. Both sequential
test instances exited normally. The existing gallery image shows the earlier
historical read-only viewer; a new editing screenshot is still needed.

Dirty application Quit, Save and Reload, stale-save alert,
multi-window close, mixed line endings, gap typing, reversed-side UI, signed
sandbox and light-mode acceptance remain pending. Historical editing,
complete block/file transfer controls, full encoding choice, folding, locator and complete
TortoiseMerge parity remain unfinished.

Validation: all 246 integration tests passed, including the three new editing
tests. Final unsigned Debug/App Store builds, both bundle audits and the static
Pages build passed. The App Store audit again verified universal Git 2.55.0,
its 11 Mach-O files and local commands, the Finder extension, licenses and 60
original icons. Signed execution and release approval are still unverified.

## Block transfer, Undo/Redo and Save As follow-up

Reviewed the pinned `RightView.cpp` UseLeftBlock/UseLeftFile and both-order
context entries, plus `MainFrm.cpp` pane-specific Save As. The native viewer now
offers Use other block, Use both blocks (this one first/last) and Use other file
for its editable working side. A selected difference determines the block;
caret selection or navigation selects it. Transferring excludes gaps, keeps
the target line-ending style (corrected in the selected-range follow-up below)
and preserves a missing final newline. Combining two EOF
blocks inserts a separating newline when needed. A CRLF suffix comparison bug
found by the new tests was fixed without adding blank lines.

Both transfers and typing use an owned UndoManager, with original Undo/Redo
toolbar artwork and Command-Z/Command-Shift-Z. Reload and closure clear that
window's history. Save As offers left/right pane choices in a native save sheet,
with the repository as its initial directory. Historical/binary exports retain
raw bytes. The editable pane exports its draft with the original BOM/encoding;
export does not save that draft back to the source or clear its dirty state.

Two new core tests cover replacement, insertion, deletion, reversed transfers,
both block orders, CRLF, EOF and byte-distinct Unicode, invalid difference
selection, binary export and encoded draft export. One native QA process
verified whole-file transfer, Undo/Redo, both blocks with the working block last,
Save As of the resulting draft and exact exported bytes. Its source working
file, parent/child HEADs and index bytes stayed unchanged. The draft was undone
before normal Quit, and process absence was verified. The inspected unedited
capture `two-file-edit-dark.png` shows the current toolbar and transfer controls.

Native arbitrary multi-line block selection/context menus, marked-block
operations, left-pane export, binary export, other block order, reverse-side
editing, undo caret restoration and keyboard shortcuts still need acceptance.
Historical editing, light-mode capture, full image controls, word diff, locator,
folding, complete settings and signed sandbox execution remain unfinished.

Validation: all 248 integration tests passed. Unsigned Debug and App Store builds,
both bundle audits and the static Pages build passed. The App Store audit
verified the universal Git 2.55.0 runtime and its local commands, embedded Finder
extension, licenses and 60 original icon resources. These are packaging and
compilation checks; signed activation and release approval remain unverified.

## Pane context menus and selected-range transfer follow-up

Reviewed the pinned [BaseView.cpp](https://github.com/TortoiseGit/TortoiseGit/blob/7338078f8ddd924b8cddee35f512f2286072136d/src/TortoiseMerge/BaseView.cpp)
selection and UseViewBlock implementation, and [LeftView.cpp](https://github.com/TortoiseGit/TortoiseGit/blob/7338078f8ddd924b8cddee35f512f2286072136d/src/TortoiseMerge/LeftView.cpp)
context actions. Both native panes now provide menus with original transfer,
Save As, Undo/Redo and Copy icons; Cut/Paste use native macOS symbols. The source
pane offers Use this block/whole file; the working pane offers Use other
block/file. Both-order actions interpret “this” as the pane that opened the menu.
Commands honor editing, busy and Quit-confirmation state.

A selected range takes precedence over the navigated difference and can include
unchanged lines and alignment gaps. Upstream inclusive block endpoints include
the next line when the selection ends at its column zero. Incoming ended lines
use the target LF/CRLF style; missing final newlines remain absent. Copy/Cut map
the display selection back to actual bytes, excluding gaps and artificial EOF
newlines. Deferred selection notifications are discarded after alignment changes.

Two new core tests cover multi-difference range transfers, reverse sides, invalid
ranges, target line-ending conversion, inclusive selection endpoints, UTF-16
emoji offsets, gap exclusion and exact CRLF/EOF copy text. One native QA process
verified both pane menus, working-pane last/source-pane first ordering, Cut and
Undo. The draft was restored before normal Quit; process absence, source bytes,
both repository HEADs and both index files were verified. Native arbitrary
multi-line transfers, Paste/clipboard acceptance, reverse-side editing, marked
blocks and signed sandbox execution remain pending. Earlier screenshots remain
accurately labeled and do not depict these newer context menus.

Validation: all 250 integration tests passed. Unsigned Debug and App Store
builds, both bundle audits and the static Pages build passed. The App Store
audit exercised universal Git 2.55.0 local commands and verified 11 Mach-O files,
the Finder extension, licenses and 60 original icon resources. Signed runtime
behavior and release approval remain unverified.

## Marked-block follow-up

Reviewed the pinned RightView MarkBlock/LeaveOnlyMarkedBlocks context entries
and BaseView MarkBlock, UseViewBlock and its skip predicates. The working-pane
menu now offers Mark block, Unmark block and Leave only marked blocks. Single
rows show the applicable mark action; multi-row selections offer both. Marking
requires an editable working pane and follows the same busy/Quit gates as edits.
The unchanged upstream `src/Resources/linemarked.ico` blob was verified against
`33975e0b218b36be8dc5c788bc8baba6d7f02780`; its SHA-256/source path is recorded
in the icon manifest. It appears in menus and the numbered working-pane gutter.

Marks and manually edited row flags participate in the existing Undo history.
Row flags follow insertions, replacements, deletions and alignment gaps; direct
block/file replacement clears flags in the replaced range. Leave only marked
blocks retains marked or typed rows, replaces the rest from the other pane using
the destination line-ending style, and consumes all marks as upstream does.
A formerly final line gains a separator if it now precedes additional lines.
Reload clears annotations; Save records the current mark state. Marks are view
metadata and do not become file bytes or index entries.

Two new tests cover marked/typed preservation, unmarked replacement, gaps,
reverse sides, target endings, EOF separators, invalid row flags and annotation
remapping through insertions/replacements/deletions. One native QA process
verified Mark, original gutter artwork, mark consumption with preserved text,
Undo of consumption/marking, retained manually typed text and replacement of an
unmarked original line. All drafts were undone before normal Quit. Process
absence and unchanged source bytes, both HEADs and both index files were checked.
The inspected unedited capture is `two-file-marked-dark.png` in the Pages gallery.
Native multi-block marking, reverse-side editing, gap marks, Unmark/Redo/Save
variants and signed sandbox acceptance remain pending. Full source state
transitions, three-way marked operations and TortoiseMerge parity remain partial.

Validation: all 252 integration tests passed. Unsigned Debug and App Store
builds, both bundle audits and the static Pages build passed. The App Store
audit exercised universal Git 2.55.0 local commands and verified 11 Mach-O files,
the Finder extension, licenses and 61 original icon resources. Signed activation,
sandbox acceptance and release approval remain unverified.

## Inline character/word display and Log integration follow-up

Reviewed the pinned [SVNLineDiff.cpp](https://github.com/TortoiseGit/TortoiseGit/blob/7338078f8ddd924b8cddee35f512f2286072136d/src/TortoiseMerge/libsvn_diff/SVNLineDiff.cpp)
ParseLineWords/ParseLineChars and ShowInlineDiff, BaseView GetLineColors and
InlineViewLineDiffColor, and MainFrm OnViewInlinediff/OnViewInlinediffword gates.
The two-file viewer now offers Inline diff and Word diff session toggles. Inline
is initially on in character mode; Word diff is disabled when inline display is
off. These display controls do not edit source bytes or add Undo entries.

`MergeInlineComparison.swift` returns exact UTF-16 spans and opposite-pane
missing-text positions. Word mode groups alphanumeric runs and ASCII space/tab
runs; punctuation is separate. Character mode compares UTF-16 units. Shared
tokens must exceed half the changed tokens plus the number of change groups,
matching the upstream similarity gate. Empty/equal lines, gaps and dissimilar
pairs retain their existing row colors. The 3,000 UTF-16-unit limit applies to
each displayed pane independently, allowing a short side to compare against a
longer opposite side. Results are cached per alignment and word mode.

The original DiffColors defaults now render common text in lavender, removed
spans in red and added spans in pale yellow, with their corresponding dark-mode
values. Missing text has a narrow red marker. Changing mode or editing rebuilds
the display spans and markers without inserting display-only characters.

Native acceptance found ordinary Log comparisons still opened unified diff.
Normal repository Log now routes one revision against working tree, first parent
(or empty tree for a root commit), or two revisions into the retained Changed
Files factory. Show changes as unified diff remains a separate command with
its original unified-diff icon. History-selection dialogs without a comparison
factory disable comparison commands; full picker integration remains pending.

Three new tests cover exact character/word ranges, UTF-16 emoji/NFC/NFD offsets,
whitespace/punctuation, insertion/deletion markers, empty/equal/dissimilar pairs
and asymmetric/over-limit lines. Two sequential native QA processes were closed;
the first exposed the Log routing gap, the updated build verified Log → Changed
Files → two-pane viewer. Character/word toggles, opposite insertion marker,
similarity fallback, light/dark colors and disabled-inline full-row restoration
were checked. Inspected unedited gallery captures are `two-file-inline-dark.png`
and `two-file-inline-light.png`. Process absence and unchanged fixture HEAD,
index and working-file bytes were verified.

Swift's diff engine replaces libsvn matching; repeated-token tie behavior and
platform Unicode alphanumeric classification can differ. Exact libsvn parity,
inline navigation, EOL/whitespace markers, configurable inline colors/cutoff,
very long opposite-line performance, signed execution and history-picker/native
root/two-revision comparison variants remain pending. Three-way inline display
is intentionally still absent, matching upstream's visible-bottom-pane gate.
Full TortoiseMerge and Log parity remain incomplete.

Validation: the final full suite passed all 255 tests. Final unsigned Debug and
App Store builds, both bundle audits and the static Pages build passed. The
App Store audit exercised universal Git 2.55.0 local commands and verified
11 Mach-O files, the Finder extension, licenses and 61 original icons. These
checks establish compilation/packaging; signed Finder activation, sandbox
acceptance and App Store release approval remain unverified.

## Ordinary file Diff routing follow-up

Reviewed upstream `Commands/DiffCommand.cpp` at pinned commit
`7338078f8ddd924b8cddee35f512f2286072136d`: directory Diff opens Changed Files;
ordinary file Diff compares HEAD with working contents, and unified output is a
separate mode. The native dispatcher now opens Working Tree for directory
selections and retains two-pane comparison windows for ordinary changed files.
Finder-request startup uses this same dispatcher. Working Tree Diff and
file double-click use the same callback; Save unified diff retains its patch
export behavior. Gitlinks retain their dedicated Submodule Diff window.

The core pins HEAD before reading the comparison. Selected renamed files use
the original HEAD path, staged-plus-working edits compare with committed bytes,
and explicit untracked selections use an empty base without touching the index.
An unborn branch uses the empty tree after checking its missing branch ref;
invalid HEAD states propagate errors rather than silently becoming an empty base.
Clean selected files produce a no-changes message.

Two real-Git tests cover staged-plus-working changes, renames with literal
pathspec-looking/Unicode/newline names, explicit untracked files, duplicate
selections, path escape rejection, unborn branches and unchanged selections.
They verify exact comparison bytes and unchanged index bytes. Native QA verified
that ordinary file Finder-request startup directly opens the two-pane viewer.
The process was quit and its absence checked; fixture HEAD, index and working
bytes remained unchanged. Working Tree double-click, directory and multi-file
native acceptance remain pending, as do signed Finder activation/security scope,
external two-file command variants and alternative-tool options. Full upstream
DiffCommand and TortoiseMerge parity remain partial.

Validation: all 257 Swift tests, unsigned Debug and App Store builds, both
bundle audits and the static Pages build passed. The App Store audit verified
universal Git 2.55.0 local commands and 11 Mach-O files, the Finder extension,
licenses and 61 original icons. Signed execution and App Store acceptance remain
unverified.

## Revision selection and metadata follow-up

Both revision buttons now offer Browse References, Log and RefLog, alongside
HEAD/Working tree/Empty tree conveniences. Browse References lists full ref
names (including refs outside branches/tags/remotes) with filtering and explicit
OK/Cancel. It is a flat native chooser; the upstream browser's full tree and
context operations remain pending. Log uses the existing selectable Log window,
starting at the chosen comparison commit. RefLog uses its existing native window
in selection mode; OK requires exactly one entry, double-click accepts it,
Cancel returns no choice, and stash apply/delete/clear are disabled in that mode.
Normal RefLog behavior retains its existing inspection and stash operations.

Each comparison snapshot includes immutable commit metadata: configured short
hash, subject, mailmapped author, author date and committer date. Revision labels
show short hash and subject, with localized author/date tooltips. The newer
commit side is labelled according to committer dates. Working/empty-tree sides
have no invented commit metadata. A real-Git test verifies custom refs, default
checkout reference scope, mailmap, configured abbreviation, separate author and
committer dates, absent metadata for non-commit sides and retained metadata after
a ref advances.

One native dark-mode QA process exercised custom-ref selection, Log selection
of the earlier commit, RefLog selection of the earlier commit and RefLog Cancel.
The resulting revision fields, subjects, change lists and newer-side labels were
verified. Parent/child HEAD, child index bytes and local working text were
retained. The process was quit and absence verified. Inspected, unedited native
captures are `submodule-diff-dark.png` and `changed-files-dark.png`. Dedicated
chooser multi-selection rejection, all Cancel variants, RefLog double-click,
normal stash-mode regression acceptance and signed sandbox checks remain.

Follow-up validation: the full 237-test integration suite passed, followed by the
metadata test with fixture-relative dates. Unsigned Xcode Debug and App Store
builds passed; bundle audits verified the embedded Finder extension, licenses,
59 icon assets and universal bundled Git runtime. The static site build passed.
These build checks do not prove signed Finder activation or App Store acceptance.

## File list sorting and context actions

All five column headers now sort in both directions. Text uses literal UTF-16
ordering; Action follows the upstream action flag order; counts sort numerically
with unavailable statistics treated as zero. Each column uses the path as a tie
breaker, including reverse sorting. Selection is retained by path. Git raw diff
metadata identifies current/deleted gitlinks independently of filesystem state;
these entries remain visible if statistics are absent. Missing numstat records
for ordinary ignored-whitespace-only changes are filtered, while binary records
with `-` statistics remain.

Copy Paths and Copy All Columns preserve the displayed selected-row order, with
tab-separated fields and native LF line endings. Save List uses an NSSavePanel and
UTF-8 output containing the pinned From/To revisions followed by selected paths.
It snapshots the selection before opening the panel and writes atomically. The
Save As icon is the unchanged upstream `src/Resources/saveas.ico`, verified against
blob `8cf032d7da7ff664a917b1c53898fa156afc62d7` and added to icon provenance.

File-scoped Show Log routes each selected path to its own Log window at the pinned
destination commit, or working-tree history when appropriate. History window
identity now includes the path scope, so opening a second path does not overwrite
the first. Submodule-expanded and child-history variants remain pending.

A real-Git test covers numeric 2/12 ordering, reverse ties, action/extension/deleted
counts, binary retention, sorted clipboard fields and saved-list revision headers.
A parser test covers newline/Unicode gitlinks with absent statistics. The existing
whitespace test now requires the ignored-only file to disappear. All 239 tests
passed, including the expanded 60-icon decoding checks.

One dark native QA process verified ascending and descending added-count order,
Ctrl/Cmd-A selection and a path filter retaining the matching selected row. The
selected-file menu exposed Log, Save List and both copy actions. Save List opened
its native sheet, but automation could not complete Save/Cancel; no output file
was created. Context-menu multi-row automation also failed to resolve row targets.
Clipboard contents, disk Save completion and file Log acceptance therefore remain
unverified. Parent/child HEAD, exact index bytes and the local working file were
unchanged. Normal Quit did not dismiss the Save sheet; the finished disposable
process was terminated with SIGTERM and process absence verified. No UI success
is inferred from that cleanup. The checked menu/sheet code is still subject to
native Save/Cancel and signed sandbox acceptance.

File-list build validation: unsigned Xcode Debug and App Store builds passed,
as did their bundle audits, including the 60 original icons, embedded Finder
extension and universal Git runtime. The static site build passed.
