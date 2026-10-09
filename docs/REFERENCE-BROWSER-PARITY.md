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
All/Only merged/Only unmerged use HEAD reachability. **Current Branch** accepts
live HEAD and closes the browser, even when the current branch is filtered out
or absent from the displayed catalog. A local branch is returned canonically
for the native typed choosers; upstream returns its short name. Detached HEAD
returns its full object ID, and an unborn local branch is still selectable.
This follows `OnBnClickedCurrentbranch` and `GetCurrentBranch(true)` rather than
treating the button as a navigation shortcut. Non-local symbolic HEAD falls
back to HEAD. Git read failures remain visible errors. F5 refreshes the catalog. Column clicks change sort and
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

## Switch from a reference

Commit-object rows in working-tree repositories now offer **Switch/Checkout to
this…** with the original Switch icon. This includes local and remote branches,
symbolic remote HEAD, lightweight tags and commit-valued custom namespaces.
Annotated tag objects, blobs and bare repositories omit the command, matching
BrowseRefsDlg's object/working-tree gate.

The browser owns the existing native Switch window as a modal child and passes
the canonical reference as its initial revision. The Switch window retains its
branch/tag/commit classification, private preferences, native revision controls,
new-branch/tracking defaults, full reference/Log pickers, checkout progress and
post-actions. Parent selection, competing dialogs, refresh, close and Quit are
locked while it is open. Cancel and rejected presentation release ownership;
forced parent cleanup also closes the Switch window's nested selection picker.
The browser does not automatically reload after this dialog closes, following the
source Switch action; F5 remains available afterward.

RepositoryModel now configures all four browser consumers through one helper and
shares the existing standalone Switch change/status/log/post-action callbacks
with this owned route. The remote-only tracking picker inherits that configuration.
No RepositoryModel is instantiated by the hidden receiver, because its normal
constructor writes shared Finder settings; production factory wiring is inspected
in source while dialog configuration is captured in the native test.

See [reference Switch QA](qa/reference-switch-2026-10-09.json) and
`scripts/test-reference-switch.py`. Hidden route checks and existing real-Git
Switch progress/picker regressions do not establish physical sheets/focus/keyboard,
visual/accessibility/signed behavior. The expanded transaction receiver checks
real checkout through this owned route, captured options, all three progress-close
policies, acknowledgement locks and a post-action. Initial metadata reads publish
together and are cancelled/fenced on close. Forced checkout cleanup is now covered by the hidden receiver described below;
physical sheet/window behavior remains unverified. Complete Merge parity, Fetch, creation/tree/range/deletion commands
and the full port remain unfinished.

## Current Branch acceptance correction

The Current Branch read uses a cancellable request and live repository metadata.
Duplicate acceptance, refresh, ordinary close and other choices are blocked while
it runs; forced controller cleanup cancels the request and rejects late results.
The remote-only tracking picker can return a local Current Branch choice, as in
upstream; its owner ignores that non-remote result without changing configuration.

Core coverage includes live branch changes after a cached snapshot, detached and
unborn HEAD, bare repositories, linked worktrees, exact Unicode HEAD spelling,
cancellation and read-only repository bytes. The hidden native receiver also
covers filtered-out choices, single completion/close, owned-child locks, immediate
forced close and the owned tracking picker. These checks do not prove physical
button interaction, sheet focus restoration or concurrent external HEAD writes.

See [Current Branch checkpoint evidence](qa/reference-current-branch-2026-10-09.json)
for the tested cases and remaining limits.

## Owned checkout transaction and initial load lifecycle

The reference browser retains Switch while its progress controller is open,
including successful operations awaiting acknowledgement. The submitted checkout
options are captured before asynchronous validation; later draft changes do not
change the running checkout. Closing progress acknowledges once, releases Switch
and its browser owner, and retains the source browser catalog until explicit F5.
Current Branch then reads live HEAD, including a branch changed by that checkout.
The existing configured post-action callback receives the previous branch.

The progress presentation entry point preserves the normal native sheet path and
allows a hidden receiver to exercise the shipping controller's ownership callback.
A rejected presentation invalidates the unstarted progress model and releases its
owner without launching Git. Completion callbacks check controller identity before
clearing ownership. This does not establish physical sheet behavior.

Switch's initial catalog and branch reads now share a cancellable request, with
App Store security-scope checks and publication only after both reads finish.
Forced browser/child close cancels that request and prevents late fields or errors.
The receiver pauses each actual Git read with an owned wrapper/helper, observes
the live processes, closes the owning browser and verifies both processes exit
without publishing a partial catalog. See
[transaction checkpoint evidence](qa/reference-switch-transaction-2026-10-09.json).

## Forced checkout cleanup

Forced browser/Switch close now cancels checkout validation and the owned
progress operation, ends/releases its progress window and rejects late errors,
conflict prompts, change notifications, acknowledgements and post-actions.
Read-only checkout argument validation uses the same cancellation request as
the eventual Git switch, including reference resolution, name validation and
branch/tag existence probes. A cancelled probe remains cancellation rather than
being converted to an invalid-name/revision result or swallowed as a missing ref.

Progress collects its result locally and publishes only while its model is live.
Normal Cancel still allows conflict inspection and retry; forced cleanup cancels
that separate inspection read too. Closing a running progress window directly
releases its result while leaving the editable Switch owner available for a new
attempt. A stale completion cannot clear a newer progress controller.

Cancellation stops owned processes; it does not reverse an already completed
checkout. The receiver checks both sides: pausing before switch preserves main,
while pausing the follow-up status read leaves HEAD on older. In both cases
forced close terminates the recorded wrapper/helper and prevents late callbacks.
It also checks a pending cancellation answer, closed-model actions and a fresh
retry after forced progress close. See
[cleanup checkpoint evidence](qa/reference-switch-cleanup-2026-10-09.json).
Physical sheets, external writers, signed scopes and full source parity remain
separate unfinished gates.

## Merge context command

The commit-object/working-tree context group now includes **Merge to "branch"…**
with the original Merge icon before Switch. The current local branch is omitted;
remote branches, symbolic remote HEAD, lightweight tags and custom commit refs
qualify. Annotated tag objects and blobs do not qualify, matching BrowseRefsDlg's
object-type gate. The menu label and current-branch gate read live HEAD using its
Git-resolved admin path, including linked worktrees; detached HEAD follows the
source `(no branch)` label. The action rechecks the gate before presenting.

The browser owns the existing native Merge dialog and passes the canonical ref.
Native branch/tag popups and the commit field preserve exact UTF-8 names; a
symbolic remote preset remains selectable. The owner blocks selection, competing
dialogs, refresh, close and Quit through the Merge/progress acknowledgement.
Cancel and rejected presentation release ownership. Initial branch/reference reads
are cancellable and closed dialogs reject late metadata publication. The browser
retains its catalog after Merge, as the pinned handler does.

RepositoryModel shares the existing standalone Merge status/log/message-picker,
Abort and post-action configuration with the owned route; remote-only tracking
pickers inherit that configuration. The hidden receiver captures this hook without
constructing RepositoryModel or writing shared Finder settings. Merge now passes
its selected preference store to progress and hosting, so private receiver policies
and message history stay isolated.

The route receiver checks the actual menu/icon/order, live and linked HEAD gates,
canonical native presets including packed NFC/NFD names, ownership/rejection/close
and a real captured fast-forward merge through native progress and acknowledgement.
See [Merge route QA](qa/reference-merge-2026-10-09.json) and
`scripts/test-reference-merge.py`. Source CAppUtils user-data/rebase preflight,
full Merge chooser parity and physical sheets,
light/dark/accessibility and signed execution remain incomplete or unverified.
Tree creation, range/deletion commands and the full port remain unfinished.

Merge now uses the owned full reference browser and typed-revision Log picker.
Its forced lifetime cleanup is checked separately in
[Merge cleanup QA](qa/merge-cleanup-2026-10-09.json); picker behavior is recorded in
[Merge parity](MERGE-PARITY.md). Hidden receivers do not establish physical or
signed acceptance.

## Remote Create Branch command

Single remote references now offer **Create Branch…** with the upstream Copy
artwork after the working-tree Merge/Switch group. Local branches and tags do not
receive this single-ref command. The action captures the displayed object hash,
matching `BrowseRefsDlg::eCmd_CreateBranch`, and opens the owned native Branch
creation dialog in explicit Commit mode. Moving the remote while the dialog is
open does not change its base. Source CreateBranchTag callbacks are shared with
the standalone factory, and remote-only tracking pickers inherit configuration.

The browser blocks competing actions and normal close/Quit while the child is
owned, releases on Cancel/rejected presentation, and refreshes its catalog after
the child closes, matching source Refresh. Identity checks prevent an old child
from releasing a newer one. Forced browser closure closes the child without
refreshing a closed owner. Branch/Tag metadata and creation now own cancellation
tokens; creation validation, reference lookup, mutation and description use the
repository token. Closed models reject late metadata/errors/post-actions.

`test-reference-create-branch.py` checks actual native menu/icon, namespace gates,
private configuration, a moved remote after presentation, real branch creation
at the captured hash, refreshed browser catalog, Cancel/rejection/duplicate/
competing/close/Quit and live creation-process termination with unchanged refs.
Existing creation-picker and browser-Merge receivers remain regression gates.
Physical sheets/focus, bare/non-commit acceptance, every slow validation/metadata
stage, routed post-creation checkout/description recovery and signed scope remain
pending. Remaining source browser commands and full parity are still incomplete.

## Fetch from a remote reference

Remote references with a matching configured remote now offer **Fetch from
"remote"**, with upstream Update artwork before Merge/Switch. The source helper
`SplitRemoteBranchName` matches configured names in returned order, using an exact
name or name-plus-slash prefix. The native snapshot captures those names and uses
byte-exact matching; overlapping remote names therefore follow the source's first
match rather than a longest-prefix rule. Local and unconfigured remote refs do
not receive this action. Bare/other-object remote refs retain the source gate.

The browser owns native Fetch, presets the matched remote (not the selected branch
suffix), and shares standalone status/log/Rebase/post-action configuration. It
blocks competing commands, normal close and Quit through progress acknowledgement,
then refreshes the catalog, including after Cancel/rejected presentation. Tracking
pickers inherit configuration. Identity checks and invalidated-owner checks protect
child release/refresh. Forced closure cancels Fetch metadata/transport and closes
owned progress; late output, confirmation answers and callbacks are discarded.

Core Fetch/Pull defaults, parent-submodule metadata, remote branch browsing and
plain Fetch validation now accept owned cancellation. Fetch settings/browse reads
also validate AppStore repository access. Independent remote reads are superseded
by generation/token identity. Fetch progress cancels its process on invalidation,
fences post-await results and owns recovery/reset metadata tokens. Pending
confirmation and standalone Fetch/result windows now participate in Quit guards.

`test-reference-fetch.py` checks shipping menu/icon/order, matched remote preset,
actual local transport, held result/acknowledgement/catalog refresh, competing and
Cancel/rejected/close/Quit gates, forced metadata/transport leader/helper exit and
ignored late Cancel answers, plus standalone result Quit/acknowledgement. HEAD,
index and working tree remain unchanged. Streaming, Fetch/Rebase decisions,
cancellation and submodule-default receivers are regression gates. Physical
sheets/focus/gestures/light-dark/VoiceOver, signed Finder/AppStore acceptance,
every slow metadata/failure/prompt variant and external remote-config races remain
unverified; full menus/application parity remain incomplete.


## Single-reference deletion

The single-selection browser now offers source **Delete branch**, **Delete tag**
and **Delete remote branch** commands after the existing namespace actions, with
original Delete artwork. These depend on namespace, not working-tree or commit
object type. The current branch still receives the source command; Git rejects
deleting a checked-out branch. Notes/custom namespaces do not receive deletion.

The owned native Yes/No confirmation uses the selected canonical name. Branches
are checked for full merge into HEAD; an unmerged or unreadable relationship adds
the source warning. Tags omit that check. Remote branches also warn that the
branch will be removed on the remote. Local branches use force deletion, tags
use tag deletion, and remote branches use deletion Push refspecs against the
first matching configured remote, following source order/prefix semantics. An
unconfigured remote reference performs no deletion, matching source's empty batch.
Git argv precomposition is disabled for canonical reference operations so
canonically equivalent names remain distinct. Both deletion APIs select the
POSIX argv process path even when a caller omits a cancellation token; this
avoids Foundation Process spelling conversion for composed reference arguments.

The browser stays busy through preflight, confirmation and mutation. F5 cannot
supersede a deletion; selection, competing actions, normal close and Quit are
blocked. Yes, No and failures all refresh the catalog; failures retain diagnostics.
Forced close cancels owned Git work, aborts an attached confirmation and ignores
late answers/results. Completed Git mutations are not rolled back. Store builds
validate retained repository scope before beginning this workflow.

`test-reference-delete.py` checks hidden shipping menus/icons and captured
confirmations, No/Yes, unmerged branch/tag/local-remote deletion and Refresh,
namespace and parent/close/Quit/late-answer gates. It also pauses and terminates
recorded preflight, local deletion and Push leader/helper processes. Core tests
cover checked-out failure, bare repositories, packed canonical-equivalent names,
remote namespace effects and cancellation. See `qa/reference-delete-2026-10-09.json`
for results and limits.

Multi-selection/batch deletion, physical Yes/No/default/Escape/error sheets, every
validation timing, real remote authentication/progress, linked-worktree deletion
failures and signed sandbox/Finder acceptance still need work. Full browser and
application parity remain incomplete.
