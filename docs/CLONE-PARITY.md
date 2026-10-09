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
worktree actions disabled; see [Create Repository parity](INIT-PARITY.md). Native
bare-clone adoption and signed recent-permission renewal remain unverified.

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
Key configuration failure after Git completes reports failure while retaining the
cloned destination. Upstream shows a StorePuttyKey error and continues to the result actions; native
Clone instead retains a failed result for review.
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
