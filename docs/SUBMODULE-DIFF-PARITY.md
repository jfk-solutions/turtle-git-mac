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
ancestor, Log, Swap and View Patch. Selected files open the existing native
colored patch viewer in read-only mode. Empty selections clear the patch.
Patch refresh errors remain visible; reloading the comparison invalidates old
patch requests without leaving the patch window busy. Patch placement is
constrained to the parent screen's visible frame.

The core resolves commit names to immutable object IDs before constructing a
snapshot. Rename paths and filenames containing Unicode, newlines or pathspec
syntax are parsed with NUL records and passed literally. Comparisons against
the working tree include staged and unstaged tracked changes. Untracked files
are excluded until added to Git. Empty-tree comparisons support added/deleted
submodules. Reverse comparison uses Git's `-R`. Whitespace suppression can leave
an entry in Git's name-status list while its selected patch is empty.

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

Full revision/ref/reflog choosers and subjects, upstream Log range behavior,
column sorting and the remaining file context actions need porting. Primary
file activation currently opens unified diff; native two-file/image comparison,
alternative diff tools, blame, export and restore integration remain pending.
Conflicted gitlinks retain the existing conflict workflow and need explicit
Diff routing acceptance. Shift-alternative comparison is not wired. Dedicated
native tests for identical/missing/historical states, Log and Update handoffs,
F5, filter/swap/whitespace controls, dark mode, multi-monitor placement and busy
Quit remain. Signed Finder and sandbox security-scope acceptance are pending.
These source files and dialogs remain partial in the full-port scope.
