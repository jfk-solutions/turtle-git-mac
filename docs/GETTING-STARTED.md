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
Repo-browser for a tree object. Copy reference names copies selected canonical
names in displayed order. Revision pickers in other dialogs remain single-selection.

Single-reference menus include Fetch, Merge, Switch, creation, rename, tracking and
deletion where applicable. Some standalone and batch menus remain unfinished; see
[reference-browser parity](REFERENCE-BROWSER-PARITY.md) for the current limits.
