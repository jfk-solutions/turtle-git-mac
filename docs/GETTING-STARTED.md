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
folder and filter. Tags outside the displayed list remain intact. Remote management settings are still being ported.

Use **Delete remote tags on "remote"…** in a tag folder to open the remote tag list.
Select tags, click Delete and confirm; Abort is the default. The dialog refreshes
and stays open after deletion. Local tags remain intact. Remote folders also offer
Fetch and Delete remote tags for their configured remote.
