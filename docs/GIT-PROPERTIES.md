# Git Properties

Open **Git Properties…** from the TurtleGit app menu for the current repository
or selected paths. The Finder add-on has the same entry for known repositories.
This opens a TurtleGit window; it does not add a tab to Finder’s system Get Info
window. Signed Finder activation remains a separate distribution requirement.

The top fields show the current branch, tracked branch and its configured remote
URL. **HEAD** shows its hash, subject, author and date. **Last Modified** appears
for one indexed path and follows its content history, including the source
merge-parent selection behavior. A mode-only change does not count as a content
change. New indexed paths absent from HEAD have no last-modified commit.
The values can be selected and copied.

**Config** shows effective AutoCrLf, SafeCrLf, User Name and User Email values.
Use **Settings** to edit configuration in a sheet bound to this repository;
changing the main workspace does not change that sheet’s repository.
**Show log** opens the captured repository and selected paths.

When every selected path has an index entry, the four checkboxes show its stored
index properties. Mixed selections display an indeterminate state. Leaving a
mixed field unchanged preserves each path’s current value.

- **Assume valid/unchanged** sets the index’s assume-valid flag.
- **Skip worktree** sets its skip-worktree flag.
- **Executable (+x)** changes the stored Git file mode.
- **Symlink** changes the stored Git object type without replacing the file on disk.

Executable and Symlink exclude one another. If a selection contains a submodule,
those two mode controls are hidden. An initialized selected submodule can also
have a **Git Submodule** page for its parent’s gitlink and a **Git** page for its
own repository. Parent metadata requires permission covering that repository.
For unversioned paths or ordinary directories the index checkboxes are hidden.

**Apply** saves the changed index fields. It preserves the stored objects, staged
contents, other entries and working files. **OK** applies and closes. **Cancel**
discards unsaved fields; it does not undo earlier Apply actions. **Refresh** reads
current metadata and replaces the draft. If another tool changed the index,
Apply refuses the stale draft; refresh and review the fields again.

The window stays busy through its owned reads and writes. **Cancel operation**
requests cancellation before publication; the index is replaced atomically.
Closing a busy window normally waits for the operation. A forced close retires
its UI and keeps operation ownership until cleanup. Application Quit remains
blocked while that work is active.

Focused Core and native checks passed, with a physical light-mode check of the
selected-file window and Apply. Full Finder, keyboard and appearance acceptance
remain pending. See the
[source comparison and validation](GIT-PROPERTIES-PARITY.md).
