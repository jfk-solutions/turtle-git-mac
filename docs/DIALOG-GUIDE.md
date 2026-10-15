# TurtleGit dialog guide

These instructions describe the implemented macOS workflows. The complete
TortoiseGit port and signed Finder/App Store acceptance remain in progress.
Start with [Getting started](GETTING-STARTED.md) and
[repository folder access](REPOSITORY-FOLDER-ACCESS.md) when opening a repository.

## Clone and create

Use Clone to choose a repository URL and a destination folder. Choose an empty
or new destination, review the branch and clone options, then start the operation.
The progress window reports Git's output and offers cancellation. A cancelled or
failed clone can leave files in its destination; inspect them before retrying.

Create Repository initializes Git in the selected folder. Choose a bare repository
only when you want repository storage without a working tree. Authorize the
folder when macOS requests access. Open the resulting repository to work with it.

## Working Tree and Add

Working Tree lists changes and offers the same kinds of status filters as
TortoiseGit. Show Whole Project expands a file/folder invocation to the repository.
Show unversioned, ignored, unmodified and staged files as needed. F5 refreshes;
double-click a file to compare it. Select rows for context-menu actions. Checking
files and selecting rows are separate operations.

Add lists files eligible for the chosen Add operation. Check the paths to add,
then choose OK. Header menus control optional columns. Adding records content in
Git's index; it does not create a commit. Use Commit to finish the change.

Ignore offers repository ignore-file or local exclusion choices for the selected
patterns. Review the path and pattern before saving. Ignoring a tracked file does
not remove it from Git; use the applicable remove/keep-local workflow separately.

## Commit

Write the commit message above the changed-file list. In ordinary mode, check the
files to include. Use the Check links to select categories. Show Unversioned Files
includes new files in the list; review what is checked before committing.

Amend Last Commit changes the latest commit. Set author date and Set author
allow explicit attribution. These options rewrite commit metadata; verify them
before accepting. Message only is available for the corresponding commit flow.

Staging support (EXPERIMENTAL) enables the index-based workflow. The file list
retains its place; partial staging opens in a separate window to the right.
Review staged content as well as working-tree content before committing.

The Commit split button offers Commit, ReCommit, and Commit & Push. ReCommit
continues the commit workflow; Commit & Push hands the result to Push. A commit
or push failure is reported in its owning workflow. Read the output before retrying.
See [Getting started](GETTING-STARTED.md#use-the-staging-area).

## Log and RefLog

Log shows the revision graph before the revision list, followed by the selected
message and changed files. Use filters to narrow the displayed history. Select a
revision to inspect it; file and revision menus offer the relevant comparisons
and history operations. [Finding revisions](LOG-FIND.md) explains Log's Find flow.

RefLog shows recorded movements of a reference. Choose the reference, refresh,
and select an entry for its context actions. Reflog entries are local recovery
information. A selected commit can still require a separate confirmation before
a history-changing operation runs.

## Repository Browser and references

Repository Browser reads the tree at a pinned revision. Navigate folders, inspect
files, and use Open or Save to work with a historical copy. A historical file is
not the current working file. Review a Revert action carefully before accepting it.

Browse References lists branches, tags and remote-tracking references. Use the
filter and selected reference for the offered actions. Picking a reference in a
child dialog returns it to the caller; it does not itself check out that reference.

## Branch, tag and checkout

Create Branch or Tag asks for a name and a base revision: HEAD, a branch, a tag,
or an explicit commit. Choose the base before accepting. Branch tracking, force,
switch, signing and push options depend on the operation and reference type.

Switch/Checkout chooses the target branch, tag or commit. Review Create New
Branch, force/overwrite, merge and tracking options when available. Force can
discard working changes. A checkout failure leaves its Git output available for
inspection; resolve the reported condition before retrying.

## Fetch and Pull

Choose a configured Remote or an Arbitrary URL. Remote Branch narrows the request;
the browse button selects a remote branch. Manage Remotes opens the repository's
remote settings. Authentication uses the configured SSH/credential workflow.

Fetch obtains remote objects and references. Pull also integrates them into the
current branch. Pull offers Squash, No Commit, No Fast Forward and Fast Forward
Only where applicable. Incompatible choices disable one another. Depth is shown
for a shallow repository and is used only when its checkbox is enabled.

Tags and Prune have three states: mixed uses configuration, checked enables the
option, and unchecked disables it. The adjacent text describes the configured
default. With multiple destinations, each destination's default is used.

Launch Rebase After Fetch opens the native Rebase flow after the fetch. A branch
configured to require rebase can select that behavior automatically. Read the
progress and conflict result before starting another integration operation.

## Push

In Ref, choose the local source and remote destination, or Push all branches.
The local browse menu offers references, Log and RefLog. A source choice does not
change the checked-out branch. In Destination, choose a configured remote or an
arbitrary URL. The all-remotes choice is available when multiple remotes exist.

Force with lease and Force are distinct, mutually constrained options. Include
Tags and lease mode also constrain one another. Review the selected references
and output when replacing remote history. Set upstream records tracking;
the two Always push options save the selected remote or destination branch for
the local branch. They are enabled only for applicable source/destination choices.

Recurse submodule offers None, Check and On-demand. Push option forwards the
entered option through Git. Autoload SSH key uses the selected remote's saved
SSH configuration. Manage opens remote settings. Choose OK to start Push, then
review the progress result. Cancelling cannot undo changes already accepted by
the remote.

## Merge and conflicts

Choose the revision to merge and review the merge options/message. Commit options
control whether Git creates a merge commit automatically. A conflict leaves an
unfinished merge in the repository; it is not resolved by dismissing progress.

Use Resolve or the conflict-file context menu to open the appropriate text,
image, delete/modify or submodule workflow. Compare the named sides, save the
intended result and mark it resolved. Continue the parent operation only after
reviewing the remaining conflicts. [Conflict identities](CONFLICT-IDENTITIES.md)
explains the side captions, and [Save As targets](SAVE-AS-TARGETS.md) explains
how an exported copy differs from the actual merge result.

Comparison options can make different source lines compare equal. When Base,
Mine and Theirs still differ in their original text or endings, the merge editor
flags an **Ignored conflict**, retaining Mine text without inventing marker lines.
Use the normal conflict navigation and Mine/Theirs choices to resolve it. Undo
restores its unresolved state even when choosing Mine did not change any bytes.
Choosing a side counts as a modified result until saved, including that same-byte
Mine choice, so Close and Quit still offer to save it. Save warns while such conflicts remain; Mark as resolved stays unavailable.


In two-pane and one-pane comparison, Previous/Next difference searches from the
active pane's caret and selects the whole source-state block. Control-Up/Down, Option-Up/Down and F7/Shift-F7 use the same navigation.
In two-pane Compare, the caret also advances to the first inline difference when
inline display is enabled.
Neutral Base and Mine rows are separate stops; filtered common rows are skipped.
Collapsed sections remain collapsed, and navigation stops at the first/last block. The highlighted block has top/bottom boundary lines;
the insertion caret stays separate. Right-click selects the clicked state block,
including unchanged lines. Copy copies an existing block or text selection. Cut copies it without
deleting when no text is selected, and Paste inserts at the caret. Drag or use
Shift with navigation keys to select text for normal Cut/replace behavior.

In three-pane Merge, navigation follows the focused source or result pane.
Control-Up/Down or F7/Shift-F7 moves between differences; F8/Shift-F8 moves between
conflicts. Source-pane context menus offer block choices for the matching result
conflict. Selecting a common line disables those choices. Undo/Redo restores edited text and the target caret, and clears selections in all
panes. Sections omitted
from a pane can cause its highlighted block to span a different number of lines.

In one-pane comparison, a filtered common line can appear as a neutral pair.
Ignore whitespace changes can fold that pair, while Modified-only Find still
includes it. Ignore all whitespace changes collapses common pairs to Mine.
Save As retains both neutral rows; ordinary removed rows are omitted. Editing
uses the same retained payloads, with normal Undo/Redo and encoding controls.


## Rebase and Cherry Pick

Rebase prepares commits relative to the selected branch/upstream and optional
onto target. Review the plan and each row action before starting. Edit, squash,
skip and conflict handling can change the resulting history. Cherry Pick uses a
related replay plan over the selected commits.

When replay stops, inspect its message and Conflict Files, resolve and save the
required files, then continue through the owning replay window. Use Abort when
you intend to abandon the unfinished replay. Closing a window is not a substitute
for completing or aborting the repository operation. See
[Cherry Pick](CHERRY-PICK.md), [Conflict Files](REBASE-CONFLICT-FILES.md),
[Edit and Split Commit](REBASE-SPLIT.md) and [recovery](REBASE-REFERENCE-RECOVERY.md).

## Stash, revert, reset and clean

Stash Save records the selected working state using its offered options. Stash
Apply restores a stash without dropping it; Pop also requests removal after
application. Conflicts still require resolution. Inspect the result before
assuming that a stash has been removed.

Revert working files restores their selected state; see
[Reverting working files](REVERTING-FILES.md). Revert a commit from Log creates
an inverse change; see [Reverting a commit](REVERT-COMMIT.md).

Reset selects a revision and reset mode. Review the mode before accepting: changes
to the index and working tree depend on it. Clean removes selected untracked or
ignored content according to its options. Review its candidates; these operations
are not ordinary editor Undo actions.

## Submodules and worktrees

Submodule Add asks for the repository, destination path and optional branch.
Update works on the selected submodules and offered init/recursive/update choices.
A submodule is a separate repository. Inspect its own status and commit pointer
when the superproject reports a change.

New Worktree creates another checkout attached to the same repository storage.
Choose its path, target revision and branch options. Worktree List offers the
applicable management actions. macOS may require additional parent-folder access
for creation, movement or removal. See [repository folder access](REPOSITORY-FOLDER-ACCESS.md).

## Patches and export

Format Patch prepares selected commits as patch files. Send Patch prepares the
mail delivery workflow; review recipients, message and attachments. Request Pull
prepares a request describing the selected range and repository URL. Credentials
and mail-client permissions depend on the selected delivery method.

Apply Patch Serial applies a patch series through Git's corresponding operation.
Review/apply single patch uses the comparison/review workflow. Resolve a failed
or conflicted application in its owning dialog before continuing. A Unified Diff
document can be edited and saved without staging those edits automatically.

Revision Export saves the selected revision/subtree. It does not switch the
working tree. See [Revision Export](REVISION-EXPORT.md).

## Bisect

Start Bisect with a known good and known bad revision. Git chooses a revision to
test. Mark the tested revision Good, Bad or Skip as appropriate. Continue until
the result is found, then use Reset to leave the bisect operation. These actions
can change the checked-out revision; preserve working changes beforehand.

## Settings

Settings uses a navigation tree. Apply saves changed pages; Cancel discards their
unsaved drafts. Git, Dialogs 3 and Issue Tracker pages distinguish a read-only
Effective view from stored Local, Project, Global and System values where offered.
Select a stored source, edit the relevant values/inherit choices, then select the
Save to destination. Copying to a different destination asks for confirmation.

Git configuration writes occur field by field. A later failure can leave earlier
fields saved; inspect the error before retrying. Folder authorization may be
required for configuration files outside the repository. Changing the displayed
source reloads that page's values.

General configures the Git engine and initial setup. Appearance and Colors control
the native light/dark presentation and status/graph colors. Finder settings control
menus and overlays within macOS's extension behavior. Diff/Merge tools and Unified
Diff Viewer select built-in or external tools. Saved Data clears only the chosen
category. See [Saved Data](SAVED-DATA.md), [SSH authentication](SSH-AUTHENTICATION.md),
[Git authentication](GIT-AUTHENTICATION.md) and [Privacy](PRIVACY.md).

## Finder and permissions

Enable the installed Finder extension in macOS before expecting its menus and
badges. Open a repository in TurtleGit and authorize the necessary folders.
Finder actions use the selected paths; status badges depend on the watched
repository and published status. Signed installed-app acceptance is still pending.
See [repository folder access](REPOSITORY-FOLDER-ACCESS.md).
