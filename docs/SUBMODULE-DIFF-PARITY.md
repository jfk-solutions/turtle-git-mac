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
two-pane editing/save workflows, complete image-diff controls,
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
acceptance remain unverified. This viewer is read-only; full TortoiseMerge
editing, encoding selection, word diff, locator, folding and settings remain
part of the unfinished full port.

Validation for this follow-up: all 243 integration tests passed. Final unsigned
Xcode Debug and App Store builds passed, followed by both bundle audits. The
App Store audit exercised the universal Git 2.55.0 runtime's local commands and
verified its 11 Mach-O files, embedded Finder extension, licenses and 60 original
icon resources. The static Pages build passed. These checks do not prove signed
Finder activation, signed sandbox behavior or App Store approval.

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
