# Reverting working files

Revert replaces selected versioned files and their index entries with the chosen
baseline. It does not make a commit. Added files are removed from the index while
their working copies remain. Replaced working contents are moved to Trash for
recovery; the result offers **Show saved copies in Finder**.

Open Revert from a file list or Finder command, select the paths, review the
baseline options and confirm. The progress table records Action and Path while
Git output appears below it. The final result includes any error or cancellation
and retains recovery locations.

**Cancel** requests a stop at an operation boundary. A filesystem or private-index
Git step already running finishes first. Earlier working-file changes remain;
cancellation before final publication leaves the original index in place. Review
the refreshed status and saved copies before retrying. The confirmation preference
may ask whether to queue this cancellation; No lets the operation continue.

A failed or cancelled result offers **Retry**. Retry rereads only the originally
selected paths and their renamed counterparts. It uses their current status,
rather than the old rows, and retains saved copies from previous attempts. It does
not automatically revert unrelated modifications. An item that is no longer
versioned cannot be restored by Retry.

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
