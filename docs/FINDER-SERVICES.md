# TurtleGit selected-file Services

TurtleGit advertises thirty-six macOS Services for selected files and folders. They give
users an entry point outside Finder Sync's monitored repositories, through the
system's **Services** menu. They also work with file selections supplied by other
apps that support macOS Services. Availability and ordering are controlled by
macOS; these entries do not extend Finder Sync's ordinary context-menu coverage.

| Service | Captured operation |
| --- | --- |
| TurtleGit: Show log… | Existing Log workflow for the selected Git paths |
| TurtleGit: Commit… | Existing Commit workflow with the selected paths |
| TurtleGit: Check for modifications… | Existing status workflow for the selection |
| TurtleGit: Diff… | Two selected regular files use direct comparison; other selection counts use the existing repository Diff workflow |
| TurtleGit: Clone… | Existing Clone dialog, starting from one selected directory |
| TurtleGit: Create repository… | Existing Create repository dialog for one selected directory |
| TurtleGit: Pull… / Fetch… / Push… | Existing transport dialogs for the selected repository |
| TurtleGit: Sync… | Existing Synchronization window |
| TurtleGit: Create Branch… / Create Tag… | Existing branch and tag dialogs |
| TurtleGit: Switch/Checkout… | Existing Switch dialog |
| TurtleGit: Merge… / Rebase… | Existing integration dialogs |
| TurtleGit: Stash changes… | Existing Stash Save dialog |
| TurtleGit: Stash Apply / Stash Pop | Apply or pop the selected repository's newest stash through the existing progress workflow |
| TurtleGit: Stash List | Existing stash history window |
| TurtleGit: Add… / Revert… | Add selected files through progress or review folder contents; review selected changes to revert |
| TurtleGit: Resolve… / Resolved / Resolve conflict using ‘mine’ or ‘theirs’ | Review conflicts or run the selected resolution through its existing confirmation and progress workflow |
| TurtleGit: Blame / Diff with previous version | Existing selected-file Blame or previous-revision comparison |
| TurtleGit: Edit conflict… | Existing conflict editor for the first captured selected path |
| TurtleGit: Add to ignore list… / Ignore by extension… | Existing Ignore Type/File review with name or extension patterns |
| TurtleGit: Delete and add to ignore list… / Delete and ignore by extension… | Ignore review followed by the existing keep-local/removal confirmation |
| TurtleGit: Rename… | Existing single-item Rename dialog, including destination review and Git progress |
| TurtleGit: Delete / Delete (keep local) | Existing ordered selected-path removal, confirmation and progress; keep-local stages removal while retaining working files |
| TurtleGit: Clean up… | Existing folder-scoped Cleanup options, preview and explicit removal progress |

Clone, Create and Clean up advertise folder selections only. Clone and Create require one existing,
ordinary directory; filesystem roots, symlink leaves and Git administrative paths
are refused. Cleanup retains its source Git-folder eligibility and can capture
several folders in one repository. Dialog validation and user confirmation still apply. Two-file Diff
validates both files before comparison; selecting two directories does not turn it
into an unsupported directory-comparison operation. Git-dependent commands retain
their existing repository, working-tree and selection restrictions.

The transport, branch, integration and stash Services use the source menu
predicates after repository access and discovery. They inspect the actual
selection, working-tree/bare state, merge/bisect state and stash availability; a
stale Finder badge is not authority to launch an unavailable action. Most of
these operations require one selected item under the source rules. Fetch, Pull
and Push also accept several selected repository roots. Their batch opens each
actual transport dialog in selection order and waits for its closure and workers
to drain before proceeding. Non-root or ineligible selections report a preparation
error and are skipped; cancelling one transport dialog continues to the next root.
Closing the initiating workspace or cancelling the whole request stops the
remaining queue. Existing separate saved grants can cover the selected roots;
otherwise an owned folder chooser requests a common folder. Each root retains
its actual primary lease; metadata grants do not widen that repository boundary.
Other Git-dependent multi-path Services retain their one-repository restriction.
Selecting an ineligible item never substitutes another operation.

Opening transport, branch, switch, merge, rebase or Stash Save presents the
existing operation window for review. **Stash Apply** and **Stash Pop** execute
the explicitly selected action after permission and eligibility checks, following
TortoiseGit; Pop removes the stash only after a successful application. Stash List
opens the existing stash history. Each operation keeps its own access and
cancellation lifetime even if the workspace subsequently changes repositories.

Launch the installed TurtleGit app bundle once so macOS can discover its Services.
Select files or a folder in Finder and look under **Services** in the context menu
or Finder menu. If an entry is disabled or hidden, review macOS Keyboard settings
under **Keyboard Shortcuts → Services**. The unbundled SwiftPM executable does not
register the app bundle’s Services declarations.

## Selection and permission

The provider receives the caller's private Services pasteboard. It captures file
URL items in their original order, with a legacy filename-array fallback. It does
not read the general clipboard, execute pasted text, or split paths on whitespace
or newlines. Spaces, Unicode, punctuation and line breaks remain literal path
characters. Duplicate normalized paths are removed while retaining first-seen
order. Empty, non-file, administrative, mixed malformed and oversized selections
are rejected with a Services error. The limits are 10,000 incoming items and a
1 MiB encoded request; this is a transport bound, not a repository-size limit.

A selected URL is not authorization. The app uses its existing repository access
leases or an owned **Allow repository folder access** chooser. All requested items
must be covered before Git discovery or action dispatch. Linked metadata and
additional repository access continue through the existing discovery workflow.
For repository operations, a selected symlink stays a Git path in its containing
repository; discovery does not switch to the repository it points to. Direct
two-file comparison requires permission to read the actual file targets.
Cancelling the chooser stops the request. Its sheet, callbacks and repository
owner remain accounted for until they actually release; closing an owner or
quitting cannot turn a late reply into approval. Existing operations retain their
own cancellation behavior and do not promise rollback after a completed write.

The command and paths remain captured through permission and discovery, including
the ordered root list of a transport batch. They are
not replaced by a later Finder selection or workspace selection. A busy workspace
or Quit confirmation rejects a new service immediately. During cold startup one
typed request can wait for the workspace; a second request is rejected, and a
later dispatch rejection produces a visible workspace error. A running standalone
merge tool forwards the typed request to a separate workspace, retaining the
handoff receipt until Launch Services replies. Its private
`turtlegit://service` envelope selects the owned Services route and conveys no
permission.

## Registration and source scope

`Configuration/App-Info.plist` supplies the thirty-six `NSServices` declarations.
`ApplicationDelegate.swift` installs one provider after startup preparation,
restores a previous provider only if TurtleGit still owns the registration, and
retires pending service input during termination. Opening a menu does not execute
a Service. Invoking Add on files or a quick Resolve command explicitly authorizes
its existing Git workflow; these entries are not merely navigation shortcuts.

The pinned source comparison is TortoiseGit revision
`7338078f8ddd924b8cddee35f512f2286072136d`, particularly
`TortoiseShell/ContextMenu.cpp` selection initialization and command dispatch, and
`TortoiseShell/MenuInfo.cpp` Log, Commit, ShowChanged, Diff, Clone, CreateRepo,
Pull/Fetch/Push/Sync, Switch/Merge/Branch/Tag/Rebase, all four stash entries,
Add/Revert/Resolve, Blame, PreviousDiff, ConflictEditor, the four
Ignore/IgnoreDelete variants, and Rename/Remove/RemoveKeep/Cleanup.
Those Explorer commands are not restricted to a previously watched-root list.
macOS Services supplies the missing selected-item entry point; its system menu
placement differs from Explorer and from TurtleGit's existing Finder Sync menus.
macOS determines Services ordering and may hide ineligible types before TurtleGit
is called; semantic Git eligibility is checked in the app. Services does not
reproduce Explorer right-drag interception or per-entry shell
icons. Native operation windows retain their existing controls and source artwork.

The implementation follows Apple's
[Services properties](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/properties.html)
for file UTIs, required context, message/user-data mapping and restricted actions,
and its [service-provider lifecycle](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/providing.html).
Clone, Create and Clean up advertise `public.folder`; the other thirty-three advertise
`public.item`, with operation eligibility checked after access and discovery.
The bundle uses file services rather than treating a plain text path as a file.

## Validation and remaining acceptance

The batch adds Core selection/envelope checks and a grouped native fixture for
private-pasteboard dispatch, provider registration, startup/termination ownership,
captured repository routing and permission cancellation. The native runner is
`scripts/test-finder-services.py`; CI runs it with system and bundled Git.
The [batch evidence](qa/finder-services-family-2026-10-20.json) records the actual
executed scope and any failures. A focused local pass does not establish a hosted
CI pass or physical Services activation.

Physical Services registration, actual Finder/other-app menu gestures, localization
of Services menu declarations, signed sandbox selection access and App Store
acceptance remain unverified. Creation's early directory-type validation may need
adjustment if an installed signed Services invocation does not supply sufficient
selected-item access before the app's explicit permission chooser. System menu
visibility is separate from the existing Finder Sync activation and badge checks.
This family does not establish complete Explorer integration or whole-port parity.


## Repository workflow expansion — October 20, 2026

The [workflow batch evidence](qa/finder-service-workflows-family-2026-10-20.json)
records the new service declarations, exact request contracts, live source
eligibility and owned dialog/operation handoffs. The focused runner is
`scripts/test-finder-service-workflows.py`, using private pasteboards, repositories,
preferences and offscreen windows with system and bundled Git. It distinguishes
review-only dialog opening from actual Stash Apply/Pop effects. Multi-root transport verification also covers ordered dialogs, invalid-root
skipping, per-dialog Cancel continuation, owner-close cancellation and retained
worker/grant/Quit accounting. The previous six-service evidence remains historical
and does not certify this expansion. A later
[command-line transport batch](COMMAND-LINE.md) implements ordered original-root
iteration and source-modal successor ownership. Services shares that connected
transport lifetime while retaining its own source-menu eligibility and normalized
selection contract; CLI preserves its original path-list count and duplicates.
Physical Services registration, signed grants, menu gestures and full Finder
parity still need their own acceptance.


## Selected-file workflow expansion — October 20, 2026

Thirteen additional Services retain the source selection and live status gates.
Blame and previous-version comparison require one path. Conflict editing accepts
multiple paths and uses the first captured path, as upstream does. Mixed
repositories are refused for these operations. Captured paths never fall back to
an unrelated current workspace selection. Shift captures the alternate comparison
tool for Diff, previous-version comparison and conflict editing before discovery.

Add on selected files stages those literal paths through the existing progress
workflow; selecting a folder opens the Add review. Quick resolution uses the
existing confirmation and Git workflow. Ignore retains its destination and scope
review, and delete/ignore retains the keep-local question before removal. Mask
selection is available for source-eligible multi-selections even when some items
lack extensions; those items do not generate mask rules. Directory leaves do not
generate extension masks. Dotfiles and trailing-dot names use upstream's last-dot
suffix convention, so `.profile` produces `*.profile`. Symlinks remain Git leaves
in their containing repository.

The focused runner is `scripts/test-finder-file-services.py`. The
[selected-file batch evidence](qa/finder-file-services-family-2026-10-20.json)
records the actual grouped results. Physical Services gestures, signed sandbox
grants and complete source UI parity remain separate acceptance requirements.

## Rename, Delete and Cleanup expansion — October 20, 2026

Four further Services connect the existing filesystem dialogs for previously
unmonitored selections. Rename accepts one normalized item. Delete and Delete
(keep local) retain the ordered selection, their distinct Git/index/disk effects,
and the existing confirmation/error choices. Cleanup accepts source-eligible
folders and passes their exact repository-relative scopes into its options and
progress windows. Preview is non-destructive; removal remains an explicit choice.

Eligibility comes from the pinned shell's live rules after access and discovery.
Ordinary repository roots cannot be renamed or removed through these commands.
The source's registered-submodule-root Rename/Remove exceptions resolve against
the superproject; keep-local retains its distinct exclusion. Selected symlinks
remain literal Git leaves, preserving their targets and containing repository.
Mixed repositories, unavailable source states and invalid cardinality fail
without substituting the current workspace selection.

The native forms retain their captured repository and scope if the workspace
opens another repository. Cleanup's later options-to-progress handoff preserves
the original Services identity and permission. Retired Rename/Delete dialogs
cannot be reused while their old workers are draining. Closing an owner retires
its destination/authorization panels and confirmation sheets, fences late replies
and defers final close callbacks until actual workers and children release. Quit
also waits for open native children and detached retirement work.

The grouped native entry point is `scripts/test-finder-filesystem-services.py`.
Its private repositories and pasteboards cover actual Git effects and captured
dispatch; [batch evidence](qa/finder-filesystem-services-family-2026-10-20.json)
records executed checks and failures. Physical Finder Services menu activation,
installed signed sandbox grants and App Store distribution remain separate gates.
