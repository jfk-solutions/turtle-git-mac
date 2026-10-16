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

Context **Commit…** passes the selected rows; the footer Commit follows the
invoked scope and Whole Project. For an unversioned or ignored focused row,
choose **Add**, or hold Shift for **Add as Executable (+x)** / **Add as Symlink**
on a file. These open Add progress; mode choices change the index mode, leaving
the working file intact. Mixed-selection commands follow the focused row and
act on the captured selected paths.

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
Checkboxes update immediately after a whole-file or partial staging action. Status
labels, colors, groups and line counts retain their loaded values, as in TortoiseGit;
press **F5** to rebuild them. This keeps the row in place while staging. If a staging
refresh fails or is cancelled, refresh with F5 before committing.
Review staged content as well as working-tree content before committing.

Enabling staging closes the current patch companion and refreshes the file list.
An explanation describes checked, unchecked and mixed states; choose **Do not show
this message again** to remember that choice. Changing modes keeps the message,
checked paths and Git index. In staging mode, Commit includes the whole index,
including staged files outside the displayed scope.

Mode and patch visibility are saved per repository. If saving fails, the error is
shown and the current view stays usable; the next window uses the last saved
settings. Cancel waits for an active preference write to stop before continuing.

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

Refresh (F5) reloads references and their entries. If the selected reference was
deleted, the view returns to HEAD. Clearing or deleting the last stash instead
leaves the empty stash view until a full Refresh. You can refresh again or close
the window while history or diff data is loading. An active deletion must finish
before normal closure; **Abort** in its confirmation leaves the entries unchanged.

When a Log display filter or graph rollup hides commits, adjacent visible rows
may not form a continuous range. Compare and Format Patch still support two
selected revisions; ranges of three or more require no hidden display rows.
Combine requires a continuous selection and its checked-out-branch validation.
An all-matching filter and a complete file-scoped Follow walk keep their normal
range commands.

## Repository Browser and references

Repository Browser reads the tree at a pinned revision. Navigate folders, inspect
files, and use Open or Save to work with a historical copy. A historical file is
not the current working file. Review a Revert action carefully before accepting it.

The **Revision** button opens a single-selection Log for the displayed snapshot.
Choose a commit and press **OK** to browse it; **Cancel** keeps the current revision.
The picker hides the working-tree row and offers the configured Log actions.
When an exact object ID has a matching reference, the button can show that
reference name; its tooltip also shows the pinned object ID. Folder navigation
and file actions continue to use that snapshot until you choose a revision or
refresh. Selecting another revision retains the folder when it still exists.

Browse References lists branches, tags and remote-tracking references. Use the
filter and selected reference for the offered actions. Picking a reference in a
child dialog returns it to the caller; it does not itself check out that reference.

The browser keeps distinct Unicode spellings from Git as separate entries, even
when they look alike. Export refuses names that collide on the destination volume.
Working-tree actions report a conflict if another tracked path has the same
Unicode spelling, rather than choosing one silently.

## Branch, tag and checkout

Create Branch or Tag asks for a name and a base revision: HEAD, a branch, a tag,
or an explicit commit. Choose the base before accepting. Branch tracking, force,
switch, signing and push options depend on the operation and reference type.
Cancel stops active creation or loading and waits for its processes to finish;
when configured, confirm the running-process question first. A branch or tag
already created is retained. If only its description failed, **Retry description**
saves that description without recreating the branch or switching again.

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


When first-difference navigation is enabled, Compare opens with the first state
block selected, including neutral rows in combined view. Block transfer commands
require a selected block or text range. Later keyboard, mouse or Find navigation
supersedes a pending caret restoration.

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

Typing and ordinary Cut/Paste retain the current comparison rows. Edited rows
stay where you edited them, including a removed row in combined view; untouched
removal rows keep their original appearance. Inserted lines add gaps in the
opposite pane. Undo/Redo restores the row layout, and Save retains it. Reload or
changing the view/options rebuilds the comparison. Three-pane source views stay
read-only; edit the merged result or use the source block choices.

Undo follows the most recent edit across both comparison panes. An edit that
leaves the same text still marks that pane modified after Save. Undo/Redo can
return to the saved state. When both sides of an alignment gap become empty,
the redundant row disappears; ordinary blank lines remain.

Changing comparison options or the active regex filter asks about unsaved work.
With two modified panes, choose Save left, Save right or Save both; any pane you
do not save reloads from disk. Don't Save reloads both, and Cancel keeps the
current draft and options. Accepted changes clear Undo/Redo history. Failed Save
leaves the current options and draft available for recovery.

In three-pane Merge, navigation follows the focused source or result pane.
Control-Up/Down or F7/Shift-F7 moves between differences; F8/Shift-F8 moves between
conflicts. Source and result context menus offer Mine, Theirs and both ordering
choices for selected ordinary or changed source blocks, as well as unresolved
conflicts. A choice affects the captured block even if you later move the
selection. Removed source rows and empty alignment gaps do not become saved
content; choosing the unchanged opposite side can restore text at that position.
After choosing Mine or Theirs for a conflict, select an individual line to take
the other source for that line while retaining its neighbors. Undo/Redo restores
the earlier choices. The result overview uses logical row counts rather than
counting each conflict marker as another conflicted row.
Choices retain source colors and count as modifications even when the selected
text is unchanged. Missing mappings after manual edits disable the affected
choices; Reload regenerates mappings and replaces the current draft after its
save/discard question. Undo/Redo restores edited text and the target caret, and clears selections in all
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

**Add** opens a multiple-selection Log. Accepted commits appear above the current
list and can repeat earlier commits. You can build an editable draft before branch
and upstream are valid. Cancel during Add keeps the previous complete plan or
draft. Cherry Pick asks which parent to use for a merge commit; cancelling the
question keeps the plan available without starting replay.

When replay stops, inspect its message and Conflict Files, resolve and save the
required files, then continue through the owning replay window. Use Abort when
you intend to abandon the unfinished replay. Closing a window is not a substitute
for completing or aborting the repository operation. See
[Cherry Pick](CHERRY-PICK.md), [Conflict Files](REBASE-CONFLICT-FILES.md),
[Edit and Split Commit](REBASE-SPLIT.md) and [recovery](REBASE-REFERENCE-RECOVERY.md).

Changed Files and Rebase's Revision Files can revert selected files to either
eligible revision. If one file fails, **Ignore** continues with the next selected
file; **Abort** stops and retains earlier completed changes. The result reports
how many files were reverted. Root comparisons offer **Revert to empty tree**,
which removes selected entries from the index without moving HEAD. Export saves
the destination revision; it does not need the Base file's contents.

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

The three-pane merge result displays removed Base records and blank conflict slots
in alignment with Mine and Theirs. Typing in a blank conflict slot resolves that
line while leaving neighboring conflict lines unresolved. Multiline paste inserts
matching source gaps, and Undo/Redo restores all three layouts. Saving writes file
content and remaining conflict markers; it omits untouched removed rows and gaps.

“Mine then Theirs” and “Theirs then Mine” keep the result aligned and show matching
gaps in both source panes. You can continue choosing or editing individual rows
afterward. Selecting a single unresolved source row resolves only that row.
Resolved conflict gaps stay visible in the resolved color without becoming saved
blank lines. Rows disappear only when all three panes contain ordinary gaps;
Undo/Redo restores the entire layout.

Result whitespace commands and Encoding/EOL choices preserve aligned rows and
conflict/resolution colors. The format ribbon reports real row endings. The
selected output ending also applies to subsequent typing and source choices.
Encoding/EOL changes can be undone together; Save keeps the chosen format.
While the Encoding dialog or Save is active, edits and Undo wait for it to finish.


## Dock progress

Git command windows show progress in the application Dock. Green indicates running
work, yellow indicates a waiting replay/question and red indicates an open failed
result. Successful completion clears its indicator; close an inspected failed
result to clear it. Other running windows keep their progress. Unknown work uses
an animated segment, which stays still with macOS Reduce Motion enabled. See
[Dock progress](DOCK-PROGRESS.md) for simultaneous-operation behavior.


## Open patch documents from Finder

Choose TurtleGit in **Open With** for a `.patch` or `.diff` file. It opens an
independent Unified Diff window, preserving the active repository. You can edit,
Undo and Save the document. Reopening the same file focuses its existing window
and keeps unsaved edits. Applying it to a repository remains a separate command.
See [application and document identity](APPLICATION-IDENTITY.md).


## Complete a destination path

Clone, New Worktree, Rename and Export offer filesystem matches while you type a
path. Right-click the field and choose **Complete Path** to request matches
explicitly. Choose a match with the native completion list; directory matches end with
`/`. Relative paths stay relative, and selecting a `~/` match fills its absolute
path. Use Browse when a destination needs a macOS access grant. Completion does
not create, move, clone or export anything until you confirm the dialog.

ZIP archive comparisons can use the bundled read-only names/date/size inventory.
See [ZIP comparison](ZIP-COMPARISON.md) for Settings → Diff Viewer → Advanced →
Restore Defaults, raw Shift comparison, and the metadata-only scope.

Bundled [binary and Mathematica comparisons](BUNDLED-COMPARISONS.md) also use the
Diff Viewer associations. Binary results are read-only; notebook comparison opens
a generated Compare Notebooks button in the associated notebook application.

[Microsoft Word comparison](WORD-COMPARISON.md) creates a new result with tracked
formatting changes. It needs Word and your macOS Automation permission. Shift
keeps the ordinary internal comparison; the originals remain unchanged.

[Word merge](WORD-MERGE.md) prepares a private three-way document. Review it in
Word and Save As the original conflicting path. Blocking mode offers an explicit
Mark Resolved/No question; Word has no trusted exit status.

[Excel comparison](EXCEL-COMPARISON.md) uses full or fast workbook modes with red
changed-value highlighting, reference/hidden-sheet colors and protection warnings.
It requires Excel; original workbook bytes remain unchanged.

### Image versus text comparison

Normal two-file comparisons choose IDiff for the source image extensions unless
an explicit filename/extension association overrides them. Hold Shift when
starting the comparison to use Merge instead. Disabled image associations also
use Merge; Shift activates their saved tool. A selected viewer stays selected on
Reload even if Settings changes. Invalid image data shows its decode message in
IDiff. Use **Load Images** to view image content with arbitrary filenames; this
explicit command does not invoke configured external diff programs. Explicit
Merge Open/source comparisons stay in the Merge editor.
