# Blame File Open and recent files

Use **File → Open** in Blame to inspect another tracked file in the same window.
**Recent Files** lists up to four successfully opened HEAD documents. Opening a
file starts at line one and retains an existing Find panel and its search text.
**Settings** opens the Blame settings page; **Close** closes the current window.
See [Blame menus and panes](BLAME-MENUS.md) for annotation menus, navigation and
pane layout.

## Files, revisions and folder access

File Open displays the committed file at HEAD. **Reload** refreshes that HEAD
version after another commit. To inspect an older revision, open Blame from Log;
historical documents do not replace the Recent Files list.

A file outside the currently authorized repository may require a repository-folder
permission sheet. Choose the root containing the file and its Git metadata.
Cancelling that sheet or a failed Git read keeps the current document available.
While another document is preparing, cancel the opening operation before starting
another Open or closing normally. Cancellation retains ownership until the read
finishes; Quit waits for that work too.

Recent Files retains the selected file's own name and repository access, including
Unicode and control characters. A moved repository can be reopened through its
saved permission when macOS resolves it. An unavailable or invalid entry reports
an error and retains the current document.

For linked worktrees and repositories using another folder for Git metadata or
objects, Open and Recent Files may ask for an additional folder. The sheet explains
why it is needed and opens at that folder, including hidden folders such as `.git`.
Choose that folder or its parent. Cancel or a wrong folder retains the current
document and recent list.

Recents remembers those additional permissions with the file. Older entries and
unavailable extra permissions can be repaired through the same folder sheet when
reopening. The selected repository remains the working folder; granting access to
its metadata does not switch Blame to that folder. Closing or cancelling while the
sheet is open refuses late replies and waits for the owned preparation to finish.

## Recent-file warnings

If a bookmark or the private recent-file archive cannot be saved after a file
loads, the annotation and embedded history remain usable. A separate recent-file
warning explains the storage problem. After correcting access or storage, Reload
retries registration and clears that save warning when it succeeds.

When Git data is available but its text cannot be decoded, choose a suitable
encoding to recover the retained bytes. The file joins Recents after a readable
HEAD snapshot is available. Reopening or closing a document retires its old
callbacks, so they cannot change the new document or its warnings.

## Zooming and reading a line's revision

Use **View → Zoom In**, **Zoom Out** or **Actual Size** in Blame. The shortcuts
are Command-Plus, Command-Minus and Command-0. Command-Equals also zooms in.
Command-wheel, Control-wheel and trackpad pinch work over source and attribution.
Zoom changes both together, including wrapped rows, and keeps your selection and
scroll location. It applies to the current document; Actual Size restores the
font configured in Blame settings without changing that setting.

Hover a source line or its attribution to read its full revision, author/email,
date and message preview. Different origin filenames are included when relevant.
Long messages are bounded, and the preview follows the hovered line rather than
the current selection. The [source comparison](BLAME-PRESENTATION-INTERACTION-PARITY.md)
records the implementation scope and remaining physical acceptance.

## Symbolic-link files

Blame treats a versioned symbolic link as a Git file. Its source is the committed
link-target text at the requested revision, including a target that is missing,
a directory or outside the repository. It does not open that target. The usual
HEAD default also means changing the link on disk does not change its displayed
attribution until the committed revision changes.

File Open and Recent Files retain the link's own name. Their repository grant
covers the selected entry's parent and Git metadata; no target-file grant is
needed. A parent directory that redirects outside the granted repository remains
unavailable. Gitlinks/submodules and directory trees are not Blame documents.

The same entry is supported by Repository Browser, Log's historical and working
file actions, Finder/command-line routing and the existing source/history
navigation. Follow-renames, previous-revision Blame and Reload retain the named
Git path. A checkout with `core.symlinks=false` can still display the committed
link blob even when its working file is a regular surrogate.

See [source comparison and scoped evidence](SYMLINK-BLAME-PARITY.md) for the
actual grouped checkpoint and remaining physical/signed acceptance.

## Reading the embedded Log

The Log pane shows the file's revision history. Colored labels identify local
branches, remotes, tags and other references, using the same colors as the main
Log. The current branch has its own color, annotated tags have a pointed label,
and the repository's HEAD revision is bold. These values belong to the loaded
history snapshot; Reload refreshes them after references change. Labels do not
add unrelated commits to the file's history.

The Log font preference applies to this pane when **LogFontForLogCtrl**
is enabled in Advanced settings. The font comes from the message-editor font
settings. Rows grow with that font. This is
independent of the source/annotation font and the source's temporary zoom.
Multiline control characters use visible one-line substitutes in list captions;
tooltips and Copy retain the original text.

Use the column header menu to show or hide metadata columns. Graph visibility
follows the complete-log/follow-renames mode and cannot be changed independently
in that menu. Message can be hidden. Column order, visibility and widths are
saved for Blame separately from the main Log. **Reset columns** asks before
restoring source defaults and fitting the current contents and headers. Fitting
the Message column includes its reference labels.

When **Diff by double-click in log** is enabled, Return or a double-click compares
the first selected revision with its first available parent. Multiple selection
keeps the other selected revisions highlighted. Shift chooses the alternate
comparison tool. Control-Return keeps its normal native handling. Parent menus
retain their explicit parent choices and historical filenames.

Header actions and delayed comparisons retain their originating document and
selection. Replacing or closing that document retires those actions rather than
applying them to the newly opened file. See the [embedded Log source comparison](BLAME-HISTORY-PRESENTATION-PARITY.md)
for the implemented scope, grouped checkpoint and remaining physical/signed
acceptance.

See [File Open source comparison and checkpoint history](BLAME-FILE-OPEN-PARITY.md)
for implementation evidence and platform acceptance limits.
