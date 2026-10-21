# Find the commit that introduced a problem

Bisect checks out revisions between a known good commit and a known bad commit.
At each step, test the checked-out version and tell Git whether the problem is
present. Continue until Git identifies the first bad commit, then Reset to return
to the branch or revision where you started.

## Start a search

Open **Bisect start…** from the repository commands. Enter **Last known good**
and **First known bad** as commit hashes or references. Bad initially uses the
current branch or HEAD; Good starts empty. Each field offers branch, remote branch
and tag choices. The adjacent Log button lets you choose one commit.

The Log picker opens at the field's captured revision and selects that commit.
Choosing a commit changes only that field. Cancel preserves your draft. You can
also start from two selected commits in Log: the first displayed selection is Bad,
and the last is Good.

Use the Form menu to focus Good or Bad with Command-Option-G or
Command-Option-B. Source Option mnemonics remain available outside text editing.
Press OK when both values are filled in.

Bisect checks out other revisions. Commit or otherwise preserve your work first.
If tracked changes are present, the dialog offers Abort or Stash. An accepted stash
is kept for later; it is not automatically reapplied when the search ends.
Untracked files are not included in that stash and can still prevent a checkout.

## Test each revision

The progress view shows command output and the revision currently being tested.
Run the build or test that reproduces the problem, then choose the appropriate
completion action from the split button:

- **Bisect good** means this revision does not have the problem.
- **Bisect bad** means this revision has the problem.
- **Bisect skip** means you cannot test this revision reliably.
- **Bisect reset** ends the search and asks Git to restore its recorded starting
  branch or revision.

The primary button runs its displayed action; the arrow opens the available
actions with their icons. If the checked-out revision has submodules, **Submodule
Update…** is also offered. Update those submodules before testing when necessary.
Existing searches can use custom terms; their actual terms appear in captions.

Repeat after each checkout. A reported first bad commit remains part of an active
Git bisect session until you Reset. Keep the commit hash if you want to inspect it
in Log later.

## Failure, cancellation and recovery

Read the output when a command fails. Git may already have started a session or
checked out another revision. The dialog refreshes its state and retains Reset
when an active session remains. A failed result does not offer another Good/Bad
classification until recovery; do not assume failure restored the original branch.

Cancel requests cancellation of the current command and may ask for confirmation.
The window retains its active work until it has stopped. Closing a window does not
perform a hidden Reset or discard a saved stash. Reopen Bisect to inspect an
existing search, or choose Reset explicitly when you want to end it.

Finder commands act on the current revision of the selected repository. Log
classification commands act on the selected commit. These can be different, so
check the selection before marking a result.

[Source parity and validation](BISECT-PARITY.md) record the implemented behavior
and remaining physical, accessibility, signed Finder and distribution acceptance.
