# Getting started with TurtleGit for Mac

This first manual chapter covers opening a repository, committing and inspecting
history in the development app. The complete port and manual remain in progress.
For build and signing instructions, start with the [project README](../README.md)
and [distribution guide](DISTRIBUTION.md).

## Open, clone or create

Use **Open Repository…** (Command-O) to select an existing repository folder.
Use **Clone…** (Command-Shift-C) for a remote or local source, or **Create
Repository…** (Command-Shift-R) for a new repository. Clone has its own options
and progress windows; inspect the result before continuing. A failed Clone can
leave partial files: retry does not delete them for you. See [Clone parity](CLONE-PARITY.md)
for supported options, cancellation and remaining authentication work.

Opening a working repository enables the status, commit and history workflows.
Bare repositories support history and remote operations but do not have a
working tree to edit or commit. If saved folder access cannot be renewed, select
the folder again through Open Repository.

## Commit with checked files

Open **Commit** for the current repository. The message sits above the changed
file list. With **Staging support (EXPERIMENTAL)** off, check the files whose
current whole-file contents you want to commit. Highlighting a row is separate
from checking it. Category links such as All and None change the checked set.
Unrelated staged changes are preserved outside the checked-file commit.

**Show Unversioned Files** includes files that Git does not yet track. **Show
Whole Project** expands a scoped selection to the repository. Double-click a
file to inspect its diff before committing. **Do not autoselect submodules**
controls automatic submodule selection in checked-file mode; it is disabled in
staging mode.

The dialog includes **Amend Last Commit**, **Set author date**, **Set author**
and **Message only**. The commit choice offers **Commit**, **ReCommit** and
**Commit & Push**. Options have eligibility rules; inspect the enabled controls
and result before continuing. [Commit parity](COMMIT-PARITY.md) records their
source comparisons, verification and remaining work.

## Use the staging area

Enable **Staging support (EXPERIMENTAL)** to use the Git index. The same file list
shows unstaged, staged and mixed checkbox states. Mixed means that a file has
both staged contents and later working-tree changes. Stage/Unstage commands act
on selected rows; enabling the mode alone does not change the index.

Staging mode commits **all staged changes**, including changes outside the
currently displayed scope. Later unstaged edits remain in the working tree.
Inspect the staged diff rather than relying on highlighted rows.

Partial staging opens an attached patch window to the right of Commit. Select
lines or hunks to stage or unstage. It changes the index while preserving
working-tree contents; a stale patch is rejected. Partial operations currently
support ordinary modified UTF-8 text files. Other file types require whole-file
staging; see the [Commit audit](COMMIT-PARITY.md) for exact limits.

## Inspect history and differences

Open **Log** to inspect the revision list with its graph before the list columns.
Revision and file context menus provide history and comparison commands, with
original upstream artwork. Colored unified patches and native file comparison
windows are available through supported routes. See [Log parity](LOG-PARITY.md),
[Log graph](LOG-GRAPH.md) and [comparison parity](SUBMODULE-DIFF-PARITY.md) for
implemented commands and remaining differences.

The existing [Commit screenshot](site/assets/commit-controls.png),
[partial-staging screenshot](site/assets/partial-staging.png) and
[Log screenshot](site/assets/log-messages.png) show actual native windows at
previous development checkpoints. Updated screenshots and the remaining manual
chapters still need work; see the [manual plan](MANUAL-PLAN.md).

Return to the [documentation index](README.md) for other workflows.


## Browse references

Choose **Browse References** in the TurtleGit menu or sidebar to inspect branches,
tags and other reference namespaces. The standalone window supports multiple
selection. Select two references and use their context menu to open a Log range;
the last selected reference is the right endpoint. Double-click opens Log, or
Repo-browser for a tree object. Copy ref names copies selected shortened
names in displayed order (branch names, or tags/remotes with their namespace). Revision pickers in other dialogs remain single-selection.

Single-reference menus include Fetch, Merge, Switch, creation, rename, tracking and
deletion where applicable. Some standalone and batch menus remain unfinished; see
[reference-browser parity](REFERENCE-BROWSER-PARITY.md) for the current limits.


To delete several references, select branches, tags or remote branches from one
namespace and choose **Delete N…** in the context menu. Review the confirmation:
remote branches are removed on the remote, and branch batches do not check whether
every branch is merged. A failed batch can leave earlier deletions completed.

Select two references to use **Compare selected refs** for their changed-file list
or **Show changes as unified diff** for a patch. Comparisons follow the displayed
list order; Log ranges put the last-selected reference on the right. Unified Diff
uses the displayed object IDs even if a branch moves afterward. Hold Shift to
reverse the configured built-in/external unified viewer choice.

Right-click a branch or tag folder in Browse References to create a branch or tag
from HEAD. **Delete all tags** applies to the tag rows currently displayed in that
folder and filter. Tags outside the displayed list remain intact.

Use **Delete remote tags on "remote"…** in a tag folder to open the remote tag list.
Select tags, click Delete and confirm; Abort is the default. The dialog refreshes
and stays open after deletion. Local tags remain intact. Remote folders also offer
Fetch and Delete remote tags for their configured remote.

In **Git Synchronization**, click **Manage** beside Remote URL to edit remotes.
Use **Add New/Save** to add a name and URL, or select an existing remote and
apply its URL, Push URL, tag, prune or Push Default changes. Closing Remote
settings refreshes Synchronization's remote list and outgoing results.
Unapplied edits are discarded when you cancel. The complete Settings tree
and full upstream dialog parity are still being ported.

In Synchronization, use **…** beside Local Branch to choose a local branch and
load its tracking destination. Use **…** beside Remote Branch to choose a stored
remote-tracking reference; its remote and branch populate both fields. These
choices prepare Sync without checking out a branch or changing Git configuration.
Cancel leaves your current fields unchanged.


## Inspect commits in Synchronization

In **Git Synchronization**, open **Out Commits** to inspect the outgoing history.
**In Commits** appears when incoming history is available. Each list has a compact
revision graph and a context menu for the selected commits.

For one commit, **Compare with working tree** opens its changed-file comparison.
**Compare with previous revision** compares it with its parent; merge commits
offer a parent submenu. Root commits have no previous revision. **Show changes as
unified diff** opens the patch, and merges provide additional modes under
**Unified diff with**. **Browse repository** opens the files at that revision.

Select two commit rows to open **Compare revisions**, a unified diff, or one of
three **Show log of** ranges. The menu labels identify the endpoints:

| Range | Commits shown |
| --- | --- |
| `A..B` | Commits reachable from B that are not reachable from A |
| `B..A` | Commits reachable from A that are not reachable from B |
| `A...B` | Commits reachable from either endpoint, excluding their shared history |

A range can be empty. Menu captions abbreviate the hashes; the opened Log uses the
full commit IDs. **Compare change sets** opens a read-only comparison of the two
commit patches in displayed row order. This currently cannot compare a root
commit; merge patches follow the first-parent range behavior of TortoiseGit.

For a single commit, choose **Show branches this commit is on** to list references
whose history contains it. These can include descendant branches and tags, not
just references pointing directly at the commit. The dialog's **Show log** button
opens Log at that commit. Its reference rows provide Log, repository browsing and
comparison commands. Navigation back to a commit targets the list that opened
the dialog. If you have changed tabs, return to that commit tab to see the requested
row; reopening the tab later does not repeat an already-handled navigation.
Normal reference navigation selects the commit. Hold Shift while double-clicking
a reference to highlight the commit in italics while keeping the selection.
If its commit is outside that list, the reference dialog explains that it is not
visible; your selection remains unchanged.

Choose **Find** from a commit list's context menu, or press **Cmd+F** with that
list focused. Incoming and outgoing lists keep separate Find windows and search
positions. Search includes commit text, metadata and changed paths; Match case
and Regular Expression refine it. Click a reference to navigate to its commit.
**Shift+Return** highlights a text match without changing the selected rows.
If you switch tabs while a Find window is open, its results still belong to its
original list. See the [light Find capture](site/assets/sync-find-light.png) and
[dark Find capture](site/assets/sync-find-dark.png).

For a single commit, **Export this version…** opens Export options attached to
Sync. Choose the destination ZIP and export the whole project or a directory.
When that commit has a tag, the dialog initially selects the first tag. Use
the Branch **…** button to browse references; selecting a tag there switches to
Tag. The Commit **…** button opens Log at the typed revision so you can choose
one commit. Cancel keeps the current choice. Close the
completed progress result to return to Sync; Cancel dismisses the options. See
the [light Export sheet](site/assets/sync-export-light.png) and
[dark Export sheet](site/assets/sync-export-dark.png).

The existing [light Sync screenshot](site/assets/git-synchronization-light.png)
and [dark Sync screenshot](site/assets/git-synchronization-dark.png) show native
windows at earlier development checkpoints. See [Sync parity](SYNCHRONIZATION-PARITY.md)
for the tested commands and remaining UI, Finder and signed acceptance work.

## Standalone comparison and merging

Choose **Tools → Open in TurtleGitMerge…** without needing a repository.
Use **Merging** and select Base, Their and My files. Two selected files open a
comparison; three open a three-pane merge. You can drop a file onto a path field
or use **Browse…**. Path suggestions follow accessible folders; App Store builds
require file/folder authorization for paths outside the app container.

Three-file results start unnamed. **Save** asks for a destination; later Save
uses that file. **Save As…** chooses another destination, and Cancel keeps the
current one. Inputs stay unchanged unless you explicitly select an input file
as the output. Shared input paths are supported. If another program changes an
input or an already-saved output, reload/review the changes before saving again.

Choose **Apply unified diff** for a patch file and target directory, or select
**Use Unified Diff from clipboard**. The checkbox follows clipboard format
availability without reading clipboard text until OK. If clipboard contents
are cleared while selected, you can uncheck it and choose a patch file. See
[Merge Open parity](MERGE-OPEN-PARITY.md) for current validation and limitations.


## Text encoding and line endings

In an editable comparison or merged-result pane, choose **Encoding…** beside
its format indicators. Choose the output encoding and EOL, then OK. **Auto**
preserves mixed endings and unended final lines. Cancel changes nothing. The
chooser edits the draft; use Save or Save As to write it. A format that cannot
represent the text without loss is rejected. Go To Line uses the source file's
numbered lines, excludes alignment gaps and is unavailable for one-line panes.

In a two-file text comparison, enable **Line diff bar** to see Base above Mine
beneath the panes. Move the pointer over a line to inspect its inline changes,
spaces, tabs and original ending, even with the pane display options hidden.
The bar follows the source font, colors, word mode and horizontal scroll positions.
Its visibility is saved; one-file and ordinary three-pane views hide it. See
[Line Diff Bar parity](MERGE-LINE-DIFF-PARITY.md) for remaining acceptance.

Choose **Create patch file** in a two-file comparison's toolbar or File menu to
export a unified diff of the saved inputs. Unsaved pane edits are excluded, as
in TortoiseMerge. In **Settings → Diff Viewer → Merge Editor → Diffing**, set
**Context lines for patches** (-1 for Git's default, 0 for no context, up to 1000).
Apply saves the setting; Cancel discards changes. See
[Create patch parity](MERGE-PATCH-PARITY.md) for scope and remaining acceptance.
