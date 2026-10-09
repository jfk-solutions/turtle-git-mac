# Reference browser parity

TurtleGit's Reset, Switch, Branch/Tag and New Worktree browse routes uses a native reference browser based on
TortoiseGit `BrowseRefsDlg`, `BrowseRefsDlgFilter`, `GitRevRefBrowser` and
`CChooseVersion` at commit `7338078f8ddd924b8cddee35f512f2286072136d`.
This is a partial port. It is not full BrowseRefs or whole-app acceptance.

## Tree, list and selection

The left outline contains namespace directories, starting at `refs`; references
are leaves in the right single-selection table. Selecting an initial reference
opens its containing directory and selects its row. The list has Branch Name,
Tracked branch, Last Author Date, Last Commit, Last Author, Date Last Commit,
Last Committer, SHA-1 and Description columns. Tracking and description columns
are visible in the local-branch namespace. The split starts with a 190-point
namespace pane; resizing preserves a user's adjusted divider within that window.

Metadata includes symbolic targets, mailmapped author/committer names, separate
dates, branch descriptions and gone upstream names. Annotated tags retain their
own object ID, subject and tagger metadata rather than substituting the peeled
commit. Custom namespaces, notes, tags and remote references are selectable.
Reference keys and namespace boundaries preserve UTF-8 spelling, including
canonical-equivalent names and leading combining marks. The shared native
revision popup adds explicit menu items because AppKit
`addItems(withTitles:)` merges canonically equivalent titles; direct menu insertion
retains both entries and selection indices. Invalid UTF-8 names and
all Git Unicode argv/precomposition policies are not established by these checks.

Filter fields are Refname, Subject, Authors and SHA-1, initially all enabled.
Refname filtering uses the displayed name relative to the selected directory.
The source non-regex, case-insensitive token filter is reused, including its
post-quote prefix behavior. Show nested refs is persisted and reloads the catalog.
All/Only merged/Only unmerged use HEAD reachability. Current Branch jumps to the
symbolic HEAD reference. F5 refreshes the catalog. Column clicks change sort and
native indicators; names use macOS logical comparison, dates use numeric epochs,
and hashes use case-insensitive lexical comparison. Exact Windows sort policies,
large catalog performance and all metadata/error variants remain pending.

## Reset handoff and context commands

Reset owns the browser. Parent Reset/apply, competing previews/pickers, close and
Quit are gated while it is open and while the fresh selection catalog is loading.
OK returns the canonical reference. Branch/remote and tag results select their
corresponding Reset controls; other namespaces use the explicit commit field.
The unused commit draft survives branch/tag choices. Cancel refreshes the original
reference catalog and preserves the selected draft. The active revision control
receives native focus after the handoff. Closed or superseded requests cannot
publish a new choice. Rejected presentation releases its child without reloading.

The read-only context subset uses original TortoiseGit icons: Select, Show log,
Show Reflog, Browse repository, Compare with working tree and Copy reference name.
Log and working-tree comparison are offered for commit objects, Reflog for local
and remote branches, and working-tree comparison is suppressed in bare repos.
Reflog is owned by the browser and blocks parent selection/close until released.
Other context callbacks retain canonical names. Remote/local deletion,
fetch/push, range selection/commands, tree
context commands and complete source menu parity remain unfinished. Reset, Switch, Branch/Tag and New Worktree use this browser; complete behavior
and other chooser consumers remain pending.

## Verification and limits

`ReferenceBrowserTests` covers private real-Git metadata, annotated tags, custom
objects/namespaces, scope/token filters, exact packed Unicode references,
classification, cancellation, reachability, bare/empty catalogs and read-only
repository invariants. `scripts/test-reference-browser.py` hosts actual Reset,
reference browser and Reflog controllers without ordering windows. Detailed
checkpoint results are in [reference browser QA](qa/reference-browser-2026-10-09.json).

Hidden receivers use isolated preferences and repositories, activation prohibited,
and injected sheet presentation that releases keyboard focus from the disabled
parent. They do not establish physical sheet transfer/restoration, mouse/keyboard
or IME behavior, default buttons, accessibility, light/dark layout comparison,
error/close-during-load recovery, signed security scopes or App Store acceptance.
No current screenshots or site deployment are claimed. The whole port remains
incomplete.

## Branch descriptions

The local-branch commit context menu now includes **Edit description** with the
original rename icon, including in bare repositories. Its owned resizable native
multiline input follows the pinned BrowseRefsDlg/InputDlg call: title and hint,
existing text, shared log font, initial end caret, clean Undo history, Cancel,
Ctrl+Return to accept and InputDlg geometry. Plain Return remains multiline.
There is no optional checkbox or project log-width/minimum-length requirement at
this upstream call site. Empty text is accepted.

The write removes carriage returns and trims surrounding whitespace; empty text
unsets the branch description. Successful writes reload the browser's catalog
and retain its canonical selection. Cancel leaves config unchanged. Parent
selection, refresh and close are locked while the editor is owned. Writes lock
the editor; failures retain the draft for retry. Forced parent cleanup cancels
pending work and prevents late UI publication. Core config writes explicitly
disable Git argument Unicode precomposition to keep byte-distinct branch keys
separate. This is not a transactional fence against another process renaming or
deleting the branch concurrently.

See `scripts/test-reference-description.py` and
[checkpoint evidence](qa/reference-description-2026-10-09.json). Physical sheets,
keyboard/IME/accessibility, visual light/dark comparison and complete Scintilla
input features remain unverified or incomplete.

## Inline branch rename

Local branches now offer **Rename** with the original rename icon and F2 in the
native reference list. The branch-name cell becomes editable in place, with its
folder-relative label selected. Escape cancels, Return accepts, and ending the
edit by moving focus also accepts, as the upstream label-edit notification does.
The selected namespace prefixes the entered label: in `refs/heads`, entering
`other/topic` renames to that branch; in `refs`, the label must begin `heads/`.
The command is available in bare repositories and is not limited to commit object
rows. Remote refs and tags cannot be renamed by this command.

Git performs a non-forcing `branch -m`, preserving branch configuration and
reflog history and updating symbolic HEAD when renaming the current branch.
Invalid names, existing destinations and Git lock errors are surfaced. Success
reloads the catalog using the previous selection, matching source Refresh after
label editing: when the old reference disappears, selection falls back to the
deepest surviving namespace instead of silently accepting the new reference in the picker.
Failures retain the original catalog row. Parent acceptance, refresh, namespace
changes, competing children, close and Quit are locked during the edit/write.
Forced cleanup cancels pending work and suppresses late UI publication; it cannot
roll back an already completed Git rename.

Core and hidden native checks are recorded in
[rename QA](qa/reference-rename-2026-10-09.json). Physical inline mouse editing,
focus-change acceptance, F2 keyboard delivery, IME, visual/accessibility comparison,
concurrent external ref changes and signed/security-scope acceptance remain
unverified. The full browser command set and whole port remain unfinished.

## Tracked branches

Local commit branches in working-tree repositories now offer **Select tracked
branch** and, when a tracked branch is displayed, **Unset tracked branch**. Tags,
remote refs, other namespaces and bare repositories omit these commands, following
the pinned BrowseRefsDlg gate. Per the requested in-app icon treatment, these two
commands reuse upstream branch/delete artwork; the original BrowseRefsDlg entries
have no explicit icon ID.

Select owns another full native reference browser restricted to `refs/remotes/`,
including symbolic remote HEAD entries. It shares the browser's namespace tree,
metadata table, text/merge/nested filters, private preference store and canonical
context callbacks. Local branches, tags, notes and other namespaces are excluded
from its catalog and tree. Cancel leaves the parent and repository unchanged.
Parent selection, refresh, competing children, close and Quit are locked while
it is owned. Rejected presentation and forced parent cleanup release/cancel the
child; closed/stale callbacks cannot set tracking.

The accepted canonical remote ref is checked against configured remotes. Git's
`branch --set-upstream-to` validates the remote fetch mapping instead of writing
remote/merge keys directly. Errors use the native browser alert, retain the current selection and explain the
possible fetch-setting cause. Success reloads the catalog and tracked-branch
column. Unset removes all local `branch.<name>.remote` and `.merge` values,
accepts absent keys, and retains description, pushRemote, rebase and other branch
settings. Errors during unset refresh metadata with the error retained. Unset is
two config writes, as upstream; it is not atomic rollback across both keys.

[Tracked-branch QA](qa/reference-tracking-2026-10-09.json) records Core and hidden
native checks. Full remote picker mutation/tree/range/network menus, physical
sheet/keyboard/focus/IME/layout/accessibility, signed security scopes and App Store
acceptance remain pending. No fetch or network operation is performed by setting
tracking. The whole port remains incomplete.
