# Reverting working files

Revert replaces selected versioned files and their index entries with the chosen
baseline. It does not make a commit. Added files are removed from the index while
their working copies remain. By default replaced working contents move to Trash
for recovery; the result offers **Show saved copies in Finder**. The configured
recycling preferences can disable those recovery copies.

From Commit, Add or a Working Tree file list, Revert uses the highlighted files
directly. Modified or type-changed ordinary files ask for confirmation first.
The repository/Finder Revert command opens the selection window, where you can
review paths and baseline options. The progress table records Action and Path while
Git output appears below it. The final result includes any error or cancellation
and retains recovery locations.

When Revert has stopped, select a file result and open its context menu for
**Show Log**, **Open**, **Open With** or **Explore to**. Double-click opens the
working file; a directory opens in Finder. Explore can locate the nearest
existing folder when a result path no longer exists. Open With lets you choose
an application and can be cancelled without opening anything.

Click **Action** or **Path** to sort completed file results. Command-C copies
selected action/path lines; **Copy to Clipboard** in the context menu copies
selected paths. Command-A selects all rows. Retry starts a fresh result selection,
so an old menu cannot operate on a newer attempt. File actions pause while Revert
runs, a chooser is open or the window is closing.

The selection window also offers **Save As…** for the current working file and
**Mark for comparison** / **Compare with…** for comparing two working files.
These actions use the file where the context menu was opened. Save As copies
current bytes to your chosen destination; it does not revert or stage the file.
A Finder **Diff later** mark can supply the other comparison file. The list keeps
TortoiseGit's original translucent Revert artwork; Advanced Settings can hide it
with **ShowListBackgroundImage**.

**Cancel** requests a stop at an operation boundary. A filesystem or private-index
Git step already running finishes first. Earlier working-file changes remain;
cancellation before final publication leaves the original index in place. Review
the refreshed status and saved copies before retrying. The confirmation preference
may ask whether to queue this cancellation; No lets the operation continue.

A failed or cancelled result offers **Retry**. Retry rereads only the originally
selected paths and their renamed counterparts. It uses their current status,
rather than the old rows, and retains saved copies from previous attempts. It does
not automatically revert unrelated modifications or silently omit requested names.
Git reports a path that cannot be restored from the baseline as an error.

A versioned row can enable Revert for a mixed highlighted selection that also
contains unversioned or ignored files. All selected names belong to the operation.
With recycling enabled, their existing ordinary working files can move to Trash
before Git reports that an unknown path cannot be restored. The failed result
retains those recovery locations. The real index stays unchanged on failure;
completed working-file effects remain. Review the result and restore any needed
copies before another attempt.

The configured Git progress close policy is captured when the window opens.
Manual keeps the result open. No options closes a successful result when no
submodule handling action remains. No errors may close any successful result.
Errors and cancellations stay available for review. A pending cancellation
question delays automatic closure until its answer is settled.

When a successful result offers **Handle submodules**, it opens comparisons
between the exact restored superproject revision and the current submodule
checkout. Review those comparisons before choosing any further update.

Forced window retirement stops further work after the current protected step
and suppresses late updates. It does not undo earlier filesystem effects. Signed
Trash permissions and physical confirmation/keyboard/theme acceptance remain
open distribution checks.
