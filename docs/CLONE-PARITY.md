# Clone dialog parity

The generic Clone prompt is replaced by a dedicated native window. Baseline:
`7338078f8ddd924b8cddee35f512f2286072136d`, `CloneDlg.cpp/.h`, `IDD_CLONE`,
`Commands/CloneCommand.cpp/.h` and `ProgressCommands/CloneProgressCommand.cpp/.h`.
References: [TortoiseGit Clone manual](https://tortoisegit.org/docs/tortoisegit/tgit-dug-clone.html)
and [Git clone documentation](https://git-scm.com/docs/git-clone).

## Implemented

Clone Existing Repository contains URL/history/browse, Directory/browse, then
Depth, Recursive, Clone into Bare Repo, No Checkout, Branch and Origin Name.
An SSH-key/history/browse row precedes From SVN Repository, containing Trunk,
Tags, Branch, From revision and Username. OK/Cancel/Help follow these groups.
The File menu opens Clone with Command-Shift-C; Finder Clone requests supply the
selected destination folder. Original Log artwork appears on the Show Log action.

Depth starts at 1 and From revision at 0; SVN layout fields start at trunk/tags/branches.
Fields follow their checkboxes. Bare excludes recursive, no-checkout and custom
origin; recursive/no-checkout/custom origin disable Bare. Selecting SVN clears and
disables incompatible Git flags, and checks the three layout fields unless the URL
ends in trunk. Disabled SVN values are not sent to a normal Git clone.

URL edits derive the destination name and remove a final .git suffix. Subsequent
URL edits replace the automatically generated component while preserving a manually
changed directory. Browse uses native directory/key panels. Successful clones save
URL/key histories, parent directory and recursive preference; Cancel saves none.

Git arguments are separate process arguments, with source/destination after `--`.
Option combinations, depth/revision, NULs, branch and origin names are validated.
Execution uses an existing destination or its closest existing ancestor; failed
destinations are not deleted. Production owns a native result: failure offers Retry
with submitted options; success offers Show Log then Show in Finder in a split
action button, plus Close. Normal
and bare clones are adopted when the workspace is idle and their resolved roots
are saved to recents. Bare repositories now open in the workspace and Log with
worktree actions disabled; see [Create Repository parity](INIT-PARITY.md). Normal/bare native adoption is covered by the workspace handoff receiver below;
signed recent-permission renewal remains unverified.

The Windows Pageant/PuTTY row is adapted to **Auto-load SSH key** using OpenSSH.
Like pinned CloneCommand, native Clone loads the selected identity before cloning
and saves its path on the resulting remote before offering Log. A private agent
receives a read-only app-private key grant; Git receives its socket, not the key
path in a shell command. Successful clones save
`remote.<origin>.turtlegitsshkeyfile` (default origin), preserving Windows PuTTY
settings. Native Clone does not write `core.sshCommand`. The public Core legacy
SSH-command mode and old per-clone bookmarks remain compatibility paths.

The checkbox follows SSH URLs (including svn+ssh), saved Clone.UseSSHKey and
runtime availability; its default is on when supported, matching source's saved
true default with a native runtime gate. Key history selects its first item.
Browse remembers a read-only key grant; typing a path alone does not grant access.
Each progress retry creates a fresh coordinator. Encrypted-key responses use the
owned native response window; closure cancels preparation and rejects late answers.
Key configuration failure after Git completes is a retained warning, preserving
the successful clone and its result actions. Opening retry repeats discovery only;
see the [completion/history continuation](CLONE-COMPLETION-PARITY.md).
App Store auto-load remains unavailable without bundled OpenSSH agent/add.
Source/destination leases remain held during execution. Signed grants, real SSH
servers, physical picker/sheet interactions and recursive SSH authentication remain
unverified.

SVN controls build the pinned `git svn clone` arguments, including an optional empty
origin prefix and local-source file URL conversion. Execution preflights `git svn
--version`. The current system Git has no SVN command; this produces an error
without creating the destination. SVN execution is not verified or bundled.

## Verification

Five real-Git tests cover shallow selected-branch cloning with a custom origin,
literal Unicode/quoted directory names, bare versus no-checkout index/worktree
semantics, recursive submodule initialization, occupied-directory preservation,
pre-mutation validation, stored SSH commands and SVN argument construction. A
disposable wrapper grants file transport only for the submodule fixture. A shell
argument check confirms that a key filename containing quotes and shell-like text
remains one literal argument and does not execute its contents. No SSH server or
real private key is involved. The historical full suite at that checkpoint passed 117 tests; this is not a
current full-suite claim.

Native QA used `/private/tmp/TurtleGitCloneQA` and a separate
`/private/tmp/TurtleGitCloneResultQA` destination. Command-Shift-C opened the native
window; URL autofill and Depth/Branch/Origin enablement were exercised. SVN selection
enabled layout controls and cleared incompatible Git flags. OK showed the missing
Git-SVN error; CLI inspection confirmed no destination was created. Switching back
to Git and Retry cloned feature/status-badges at depth 1 with remote upstream.
CLI inspection confirmed matching HEAD, shallow history, clean index/worktree and
unchanged source HEAD/refs/status/index/worktree, including its mixed staged edits.
Show Log opened that clone with its selected branch and remote reference.
`site/assets/clone.png` is the actual 1640 × 948 native options-window capture.

The initial File-menu accessibility binding became stale; keyboard invocation
worked in the updated preview. After closing Log, the computer-use connection
timed out. Cancel, picker interaction and further native checks remain unverified.

## Still partial

- Native Cancel/close preservation, URL/key history relaunch, manual-directory
  changes, SSH protocol enablement, browse panels, bare/no-checkout/recursive UI
  execution, Show in Finder, minimum-width and dark appearance QA.
- Detailed libgit2 transfer rows, physical progress/cancellation and
  full upstream progress/interactive authentication acceptance.
- Real SSH authentication, physical encrypted-key/agent UI, key use after restart, signed multi-folder
  sandbox grants, out-of-scope submodules and independent helper permissions.
- Git-SVN runtime/dependencies and real SVN cloning, LFS capability/runtime handling,
  clipboard defaults, URL-handler/exact-path input and complete saved preferences.
- Bare workspace reopening, saved geometry and upstream libgit2 progress callbacks.

No complete Clone parity or App Store readiness is claimed.

## Captured native progress and retries

The options window owns a separate result until AppKit finishes dismissing its
sheet. Failure Retry retains source, destination, Git executable, every Git/SVN
option and source/destination/key access leases, recomputing the closest existing
working directory each attempt. Retry uses a fresh cancellation token and never
clears a failed/occupied destination. Failure Close returns reviewable options on
macOS; upstream closes options before running. A missing sheet presenter cancels
before cloning. Legacy no-presenter model callers keep their inline result.

Successful Git completion resolves the captured repository, saves captured URL,
recursive/parent/key preferences and invokes adoption once before acknowledgement.
Subsequent field edits cannot replace the adopted clone or saved choices. Ordered
Show Log and Show in Finder use that captured repository and original Log/Explorer
artwork. A follow-up closes the result first and cannot repeat. A fresh production
options controller prevents a second request from replacing a running draft.

The result captures AutoCloseGitProgress at submission: manual/no-options retain
success actions; no-errors closes success without choosing an action. Failure and
cancellation remain reviewable. ConfirmKillProcess uses the source Yes/No question
with Yes default. No retains the process; Yes cancels the owned process group.
Completion while a question is pending delays automatic close until answered;
late/duplicate answers cannot cancel completed work or repeat close. Native
close/Quit guards cover grants, execution and result/confirmation ownership.
Store attempts revalidate captured source/key scopes and destination scope for the
working directory, destination and discovered repository root; signed acceptance
remains unverified.

[Progress QA](qa/clone-progress-2026-10-08.json) records six focused Core tests and
four-Git native receivers for actual shallow branch/custom-origin, bare/no-checkout,
captured history/adoption/result policies, occupied preservation/review, Retry,
missing presentation and owned process cancellation. The slow wrapper creates its
own synthetic partial file at the clone boundary; this proves process-group and
file preservation, not cancellation of a live remote transfer. Physical nested
sheet/Root adoption/Log/Finder routing, source/key grants, authentication, encrypted
keys, recursive UI and real SVN/libgit2 execution remain partial. Existing Clone
screenshots predate this result and are not new acceptance evidence.

## Live command output

Clone now consumes stdout/stderr updates while the owned command is running.
Disk-backed capture remains in place and raw final streams remain byte-for-byte
available to callers. Polling supplies new bytes from each stream and drains both
at completion, including cancellation; cross-stream observation order is sampled,
not a guarantee of the original ordering between independent descriptors.

The byte-oriented GitCliOutputParser port preserves upstream local CR overlay,
remote CR replacement/empty-line rules, NUL-to-newline presentation and 8 KiB line
truncation. Input is guarded at 150 MiB; the presentation uses captured
GitOutputLimitinKiB (default 2048, bounded 16–102400), source soft truncation and
notice/drop mode. Parsed UTF-8 bytes survive arbitrary input splits. macOS also
flushes final unterminated diagnostics. ANSI display sequences are stripped while
raw results remain unchanged. A green determinate bar and phase label use positive
percentage lines; output scrolls to the end as it arrives. Retry creates fresh
parser/stream state. Post-clone metadata errors retain their full diagnostic.

[Live-output QA](qa/clone-stream-2026-10-08.json) records the exact upstream clone
captures replayed whole, one byte at a time and in uneven chunks; local/remote,
Unicode, long-line, drop/reset/tail and output-limit cases; live binary stream
fidelity before exit and final drains; and four-Git native Clone streaming/recovery
checks. The native helper splits a Unicode character and emits representative
remote percentages before a wait boundary; this proves live delivery and parsing,
not remote-server transfer timing. Physical auto-scroll/percentage/theme/accessibility
and signed acceptance remain unverified. Other dialogs have not yet adopted the
streaming callback. This is not full progress or application parity.

## Private-agent Clone verification

The [SSH Clone record](qa/ssh-clone-2026-10-09.json) distinguishes Core command
verification from hidden native receivers. Controlled local transport checks key
loading, regular/custom-origin and bare/default-origin key storage, absence of
native shell overrides, late cancellation and missing-runtime rejection. Native
receivers exercise direct/progress Clone and forced closure while a response is
pending. These checks use generated fixture keys and invocation-only local URL
rewrites; they do not prove network authentication or displayed UI acceptance.
Post-clone metadata discovery cancellation and modal browse-panel ownership still
need broader acceptance. Earlier progress/screenshot records remain historical.


## Connected creation ownership — October 14, 2026

Clone source/destination/key Browse and App Store source/destination authorization
now use owned asynchronous native sheets. Pending selection blocks competing
actions; forced closure dismisses its panel, settles the pending continuation
once and refuses late replies. Clone captures options before authorization so
a delayed permission cannot change the submitted destination or Git arguments.

Clone and Init metadata discovery now carry the owned cancellation token. Their
independent operation counts retain grants and Quit protection after forced
owner closure, while suppressing late repository adoption and result actions.
Create Repository captures warning choices, fences duplicate/retired answers,
uses cancellable init/root/bare reads and owns its final acknowledgment. Its
Cancel remains available after preparation failure. Completed filesystem/Git
effects are retained; cancellation is not rollback.

Debug compilation, six focused initialization Core tests and four unique native
cases passed across system/bundled Git after the documented fixture wait and
actual missing-presenter repairs. Core and the already-passing system ownership
case were not repeated for the native-only repair. All receivers were reaped. See
[creation batch evidence](qa/repository-creation-owned-2026-10-14.json). Physical permission,
warning and confirmation sheets, live transports, signed grants, full dialog
parity and App Store acceptance remain open.

## Completed-command and history family — October 17, 2026

The [completion/history continuation](CLONE-COMPLETION-PARITY.md) separates SSH
configuration warnings from successful transport, retains successful actions,
retries opening without recloning, and supplies native saved-history deletion.
Accepted failed submissions now retain captured history, matching source OnOK;
this supersedes earlier success-only history and failed-result descriptions for
post-clone key configuration. Physical and signed acceptance remain open.

The [repository input continuation](REPOSITORY-INPUT-DEFAULTS-PARITY.md) adds the
source clipboard/first-history defaults shared with Submodule Add. Explicit caller
URLs keep priority; prefill supplies no authorization or automatic submission.

## Workspace completion handoffs — October 18, 2026

Clone results keep the initiating workspace window, resolved root, permissions and
completion output. If that workspace is busy, the latest completed creation waits
for the current operation to release ownership. Completion does not change the
running adoption's generation or poll the busy flag. A captured transport batch is
cancelled before it can prepare another root. Already opened transport windows
keep their own repository and permissions.

The completed root goes through the ordinary repository-open path: metadata
permissions, discovery, authoritative bare/status metadata, Recents and rollback.
A retained compound lease supplies existing Git-directory/object-store grants;
it does not prompt again merely because the primary folder excludes metadata.
An explicit Open/Close accepted before handoff starts supersedes the pending
result. Closing the initiating workspace cancels queued or in-flight adoption and
rejects a later result, even when another workspace window has become current.
Closing the completed Clone result window alone does not discard its workspace
handoff. A retired Clone dialog drops browsing/result permissions and callbacks;
its active worker or pending handoff retains its independently captured grants. Pending results participate in the application's Quit gate; termination
retires them and rejects callbacks arriving afterward. Failed adoption leaves the
previous repository open and reports its error without rerunning Clone.

This is a macOS workspace adaptation of pinned `Commands/CloneCommand.cpp`,
`CloneDlg.cpp` and the Clone result actions. Windows uses a separate modal command
process and does not share this native workspace's asynchronous adoption state.
The focused receiver and actual failures are recorded in
[handoff batch evidence](qa/repository-handoffs-2026-10-18.json).
Signed sandbox behavior, physical Launch Services, unusual network filesystems,
and completion while the initial root authorization panel is modal remain outside
this batch's acceptance scope. No all-dialog visual or whole-port completion is
claimed.

## Shared command result and creation ownership — October 19, 2026

Pinned `Commands/CloneCommand.cpp` separates clone execution from `StorePuttyKey`
and its post-command Show Log/Explore or failure Retry choices. Core now emits the
actual executable/argv immediately before clone and a command receipt immediately
after subprocess/output settlement, before key configuration and repository
inspection. Source normal/SVN arguments and captured grant/SSH preparation remain.
The native CLI path does not claim libgit2 progress equivalence.

The previous plain SwiftUI output is replaced by the shared native read-only log,
original Copy controls, captured preferences/pasteboard, colored completion range,
timing/date and retained 100 percent. Unterminated command output is flushed before
the receipt footer. Later configuration warnings and opening diagnostics preserve
the actual command result. Retry starts a fresh command/parser/token attempt;
Retry opening repeats only inspection of the already cloned destination. Existing
warning-aware auto-close and source post-action order remain authoritative.

Queued submissions/retries/opening reserve actual work before scheduling.
Invalidation retains command/configuration/inspection work and grants until drain.
Native kill/panel/result/options replies settle once after actual detachment,
including forced closure and missing presentation. A stale form/control, Quit or
retired owner cannot mutate the accepted snapshot or dispatch a late child.
Intended Show Log/Show in Finder first close result and options; Log receives the
originating preferences/access and an appearance/opacity value snapshot. Forced
close drops a pending action. Workspace adoption retains its independent original
workspace owner and superseding Open/Close behavior.

[Grouped evidence](qa/repository-creation-results-family-2026-10-19.json) records
actual checks after the implementation freeze. Full physical source layout,
keyboard/VoiceOver, live SSH/git-svn/recursive transport, Windows progress backend
equivalence, signed grants/Finder and App Store acceptance remain open. Bare-folder
Finder custom icons are not introduced by this batch.

## Optional libgit2 transport continuation — October 19, 2026

The [connected Clone/Fetch/Sync backend](LIBGIT2-TRANSPORT-PARITY.md) consumes the
source global switch and per-command mask, retaining upstream CLI defaults.
It connects native progress, actual-connection HTTPS certificate review and
combined credentials to a pinned private helper. Accepted certificate exports
retain their operation lock through cancellation. The linked batch record states
actual validation and the remaining optional-backend, public and signed gaps;
older evidence above does not prove this continuation.


### Clone checkout-filter continuation — October 19, 2026

The [Clone checkout family](CLONE-CHECKOUT-FILTERS-PARITY.md) connects configured
custom smudge filters to selected libgit2 Clone and its recursive checkout option.
It distinguishes initial destination cleanup from later recursive partial work,
retains bare/no-checkout suppression and owns actual filter cancellation/progress.
Configured LFS one-shot smudge, source boundaries and grouped evidence are tracked
in that family; it does not claim persistent filter-process or complete providers.
