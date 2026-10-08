# Fetch dialog parity

Reference: `PullFetchDlg.cpp`, `IDD_PULLFETCH`, FetchCommand and `CAppUtils::Fetch/DoFetch`
at the pinned commit in `upstream.json`. Native Pull shares this implementation; see PULL-PARITY.md for its merge options
and remaining workflows.

## Implemented

The native Fetch window retains Remote and Options groups, named remote/all remotes
or arbitrary URL, remote branch and browse, Tags, Prune, Manage Remotes and bottom
OK/Cancel/Help. The upstream merge controls remain visible and disabled in Fetch.
The branch field and browse button are disabled for the default named-remote
configured-refspec fetch and enabled for URLs. A `NamedRemoteFetchAll` preference
is read, defaulting to true; its settings UI remains pending.

Tags and Prune use native three-state checkboxes: mixed omits the flag and honors
Git configuration, checked explicitly enables it, unchecked explicitly disables it.
Labels report configured named-remote defaults. An untracked branch with multiple
remotes defaults to All unless a remembered remote is available. Depth is available only for a
shallow repository, initially checked with depth 1, and requires a positive integer.
Git receives literal argument arrays, preserving branch names and URL punctuation.
Browse retrieves actual remote heads through `ls-remote` and offers a searchable
native selection sheet. Manage reuses the basic remote settings sheet from Push.
Configured Git credential helpers and SSH agents replace PuTTY key loading.
Ordinary Fetch retains success or failure in an owned progress sheet, with source
post-actions described below. Fetch → Rebase shares this owned progress and its post-execution decisions.

## Evidence

Nine real Git integration tests cover configured tracking-ref updates without
changing HEAD/index/worktree, three-state tags/prune overrides versus Git defaults,
remote branch browsing with Unicode names, URL fetch to FETCH_HEAD, shallow depth
1 then 2, all-remotes updates and invalid destination/depth/refspec requests.
Two additional Fetch/Rebase tests verify a pinned fetched branch, dirty-worktree
preservation, replay ancestry and active-session rejection. The current focused
Pull/Fetch tests passed all 18 checks within the 21-test run that also covers
registered-parent metadata. Three added tests exercise submodule branch defaults,
read-only lookup and fallback, as detailed below.

Native QA on the disposable documentation repository browsed preview-main from
its local bare remote and fetched it via URL. Tags cycled mixed → checked → unchecked.
A separate named-remote fetch populated the expected remote-tracking branch.
After both operations, HEAD and index/worktree patches matched their original
values byte-for-byte. Manage opened, selected the configured remote, displayed its
correct URL, and closed back to Fetch. A deliberately missing fixture URL showed
Git's error, retained its URL/branch, and allowed Cancel. `site/assets/fetch.png` is an actual capture.

## Remaining parity

- Launch Rebase After Fetch now opens the selected branch's native plan. Upstream
  full interactive Rebase recovery remains; native post-execution decisions are
  described below.
- Full remote reference chooser hierarchy, tag selection and histories; the current
  chooser lists heads only. Full remote settings and their mutation/recovery QA.
- Physical history deletion/completion acceptance, complete settings
  and window-size persistence.
- Streaming progress output, full progress-window layout, interactive credentials,
  network/SSH and signed sandbox runtime checks. Transport cancellation is now
  implemented as detailed below.
- Native shallow/depth, all-remotes, broader error recovery, keyboard, resize, light appearance
  and accessibility QA; integration tests alone do not establish those UI behaviors.
- Pull merge options are now native; full interactive rebase recovery remains
  pending. See PULL-PARITY.md.

This shared source/resource remains partial; Fetch compilation and narrow verified
workflows do not establish full Pull/Fetch or App Store parity.

Native Fetch → Rebase plan handoff was verified without changing HEAD; its target
is the immutable selected fetched commit. See REBASE-PARITY.md for evidence and
remaining upstream differences. The existing Fetch screenshot predates this enabled control.


## Shared editable URL and branch history

Pull and Fetch now use native editable AppKit dropdowns for arbitrary URLs and
remote branches, backed by shared `History.PullURLS` and
`History.PullRemoteBranch` preferences across dialogs/repositories. URL identity
compares exact UTF-16 units and preserves case; branch duplicate matching is
case-insensitive like the source control. Histories retain their source order,
without sorting. Branch defaults are added/selected during load; browsing adds the
selected branch to the front without saving until OK. Selecting URL mode uses a recognized clipboard link/command, otherwise
picks the latest saved URL. URL mode
also disables Launch Rebase After Fetch and its execution gate, matching the
upstream radio transition.

OK saves the URL only in URL mode, before later transport; branch history is saved
before transport for both modes. Failures retain the entries. Source history
insertion folds each CR/LF into a space and trims surrounding ASCII whitespace.
An existing first entry retains its spelling; later duplicates move to the front.
The source limit is retained: load reads 25 entries, while a new insertion can save
26 because truncation occurs before insertion. The next load reads the first 25.
Invocation uses the trimmed URL/branch rather than the history's line-folded text.

[History QA](qa/fetch-history-2026-10-07.json) records shared history across Pull,
Fetch and repositories, real URL Pull/named Fetch, failed-transport state
preservation, ordering/case/UTF-16/limit checks and a hidden native combo's ordered
items and selection callback. These are model/Git/hidden-control checks; physical
popup, text editing/completion, Shift-Delete deletion,
Windows locale/trim equivalence, light/dark and signed sandbox acceptance remain
pending. Full Pull/Fetch and application parity remain incomplete.


## Registered submodule branch default

When the child has no configured tracking branch, Pull/Fetch now read the branch
of its registered entry in the nearest parent worktree's `.gitmodules`. A child
tracking branch still wins; an absent/empty parent branch falls back to the child's
current branch. Detached HEAD can still use a configured parent branch. This is
read-only and does not initialize a submodule, rewrite config, or change either
repository's index/HEAD. Missing/inaccessible parent metadata leaves the optional
default unavailable. Symlinked `.gitmodules` is skipped by the existing native
registration guard.

The source calls `git_submodule_branch`, whose pinned implementation reads the
`.gitmodules` snapshot. This display default intentionally does not use the
parent's `submodule.<name>.branch` local override or expand the literal `.` value
as `git submodule update --remote` would (see the
[Git branch-property documentation](https://git-scm.com/docs/gitmodules)). See
[the pinned libgit2 implementation](https://github.com/libgit2/libgit2/blob/f7164261c9bc0a7e0ebf767c584e5192810a8b24/src/libgit2/submodule.c)
and `PullFetchDlg::Refresh` in the pinned upstream checkout. These distinctions
avoid silently replacing the requested upstream dialog behavior with a different
Git workflow.

[Submodule-default QA](qa/fetch-submodule-defaults-2026-10-07.json) records tracking
priority, detached/attached fallback, literal-dot behavior, unrelated/unsafe
metadata and byte-identical read-only lookup. Native model checks load the default
into both dialogs/history, Fetch the selected branch and perform a real ff-only
Pull while retaining the child branch and unrelated dirty file and preserving
parent metadata. Module names differ from paths; paths include Unicode and a
newline. Duplicate path/name collisions, includes and full libgit2 cache lookup,
renamed/worktree variants, displayed dropdowns, parent access under the signed
sandbox and other native acceptance remain pending. The full port is incomplete.


## Clipboard URL and branch prefilling

Selecting **Arbitrary URL** now reads Unicode text from the macOS pasteboard
(string, then file-URL representation). Pull first recognizes its `git pull`
prefix and then `git fetch`; Fetch reverses that order. The shared source rules
recognize nonempty lowercase HTTP/HTTPS/Git/SSH schemes, `git@` and Windows drive
paths. POSIX absolute paths and `file://` URLs are explicit macOS additions.
Unrecognized or empty text restores the latest URL history entry and retains the
current branch. A recognized URL without a parsed branch also retains that branch.

The parser follows the source's UTF-16 offsets, first-line/NUL truncation, outer
double-quote handling, case-sensitive prefix matching, command trimming and
literal-space truncation to at most two command fields. The dialog's split keeps
its source conditions: the first space must be after UTF-16 offset one and leave
more than one branch unit; surrounding matching quotes are removed only from
split fields longer than two units. Repeated spaces, one-unit branches, command
prefixes without a token boundary and quoted unsplit arguments therefore retain
the upstream behavior. This is field prefilling, with no shell interpretation or
clipboard-triggered Git operation. Selection does not save history or mutate Git;
OK still controls saving and transport.

[Clipboard QA](qa/fetch-clipboard-2026-10-07.json) records parser vectors and native
models using injected text, including preferred/alternate commands, quote/extra
argument rules, Unicode offsets, history fallback and no mutation until OK.
Real literal-path/file-URL Fetch, ff-only Pull and failed destination retention
were checked. The user pasteboard was neither read nor modified by these tests.
Physical pasteboard/radio/keyboard acceptance, complex shell quoting and paths
with spaces, platform whitespace equivalence, clipboard support in other dialogs,
physical history deletion and signed sandbox checks remain pending. Full port incomplete.


## Transport cancellation

Cancel and the window close gesture request cancellation during Fetch, merge Pull
and Fetch-before-Rebase. Controls remain locked until the operation finishes;
Cancel shows Cancelling… while the owned process group stops. Ordinary Fetch and
merge-based Pull close their owned progress/options after accepted cancellation
finishes. Fetch-before-Rebase now shares the same owned progress policy. Headless
models can retain results for inspection. Idle Cancel closes it.
A cancelled fetch does not trigger success or open Rebase. A fresh cancellation
token is created for every invocation. Merge-based Pull now retains the result in
its own progress sheet; see PULL-PARITY.md for its actions and owning-window lifecycle. Cancellation does not roll back changes
Git has already made.

The Dialogs settings page now exposes the source **Confirm to kill running git
process** preference (`ConfirmKillProcess`, default false). When enabled, Cancel
asks **The process is still running. / Are you sure to abort?**, with Yes as the
default, matching the source MB_YESNO prompt. No leaves the transport running; Yes stops it. This adapts
`CProgressDlg::OnCancel` and `SetDialogs2`; owned POSIX process-group signals
replace the Windows console/process-tree APIs. The setting is currently consumed
by Pull/Fetch and Push, rather than every operation in the application.

[Cancellation QA](qa/fetch-cancellation-2026-10-07.json) records pre-cancelled core
requests and headless native Fetch, Pull and Fetch-before-Rebase models. A real
wrapper process and its child are stopped while an unrelated process survives;
No/Yes confirmation, retained inputs, absent success/Rebase callbacks, unchanged
HEAD/index when stopped before transport, and idle close are checked. A hidden
settings layout is constructed and closed. These checks do not establish
physical Cancel/Escape/window-close/sheet interaction, light/dark/accessibility,
retry acceptance, cancellation after Git mutation, separate progress-window
layout, streaming output or signed sandbox execution. Full parity remains incomplete.


## Immediate history deletion

The shared editable histories now map HistoryCombo's open-dropdown Shift+Delete
behavior. The macOS control accepts Shift+Forward Delete and Shift+Delete
(backspace key on Mac keyboards). Only an enabled open popup owns this shortcut;
closed controls keep normal text editing. It removes the highlighted entry,
selects the next item at that index or the previous item at the end, and clears
the field when the final entry is removed. Entries save immediately without
reordering, so cancelling the dialog does not restore a removed history item.
Invalid selections and busy models do not mutate history.

Pull/Fetch URL and branch histories remain shared. Push URL/destination/server-
option histories remain repository-scoped; all five fields use the same native
receiver and source selection/order rules. A window-scoped local key monitor
handles the shortcut while the delegate reports its popup open; there is no
global keyboard monitor.

[Deletion QA](qa/history-deletion-2026-10-08.json) records immediate persistence,
next/previous/empty selection, invalid/busy gates, shared/scoped histories and
cancel/reopen retention with byte-identical Git HEAD/index/config. Actual hidden
native controls verify selected indices, popup notifications and direct native
key-handler calls for open/closed/disabled/permission gates. Events are not sent
to the app. Existing four-Git Pull/Fetch and Push history matrices also run.
Physical dropdown event routing and highlight behavior, field-editor focus,
actual Shift+Delete/Forward Delete/Escape, resize/theme/accessibility and signed
sandbox acceptance remain pending. Source return-key/wheel handling and complete
HistoryCombo parity are not established by these checks. Full port incomplete.

## Ordinary Fetch progress and post-actions

Ordinary Fetch captures its options and keeps the owning dialog locked until its
progress result closes. Success offers Show log, Reset…, Fetch…, Rebase… and
Switch/Checkout… in upstream order. Bare repositories omit Rebase, as upstream
does. Failure offers Retry, plus Show log for an all-remotes fetch. Retry reuses
the captured arguments with a fresh cancellation token; macOS retains the same
progress sheet rather than opening another progress window. All-remotes failure
can follow a successful update of another remote; Retry does not roll that back.

Reset resolves the current tracked branch when selected, then opens native Reset
with Hard selected. The Fetch result itself does not reset HEAD/index/worktree.
The other actions route to native Log, a fresh Fetch dialog, Rebase After Fetch
or Switch. Dispatch and close guards prevent duplicate actions. The original
refresh.ico now supplies the Retry icon here and in Abort Merge; upstream
IDI_REFRESH uses that resource, distinct from its ribbon Refresh bitmap.

[Fetch progress QA](qa/fetch-progress-2026-10-08.json) records real Git checks for
captured options, retained results, named/all-remotes retry, partial transport
failure, fresh tracked Reset defaults, bare action conditions, duplicate dispatch
and cancellation cleanup. It also records updated shared-history, clipboard and
submodule regressions. No main GUI is launched by these receivers.

Fetch → Rebase now uses the owned progress and source decision prompts described
below. Physical progress-sheet controls, destination windows, light/dark,
keyboard/accessibility, streaming output, network credentials and signed sandbox
acceptance remain pending. The existing screenshot shows options and predates
this progress sheet. Full application parity is incomplete.

## Fetch → Rebase decisions

Manual Launch Rebase After Fetch now follows the command-line DoFetch conditions
and order. If the local branch is equal to or newer than the fetched target, it
asks whether to open Rebase anyway (default No). If the pre-fetch conventional
remote-tracking hash, fetched target and HEAD are equal and nonempty, it next asks
whether to open Rebase for an unchanged branch (default No). These are separate
questions; Yes on the first can lead to the second. If HEAD is an ancestor of the
target, including equality, it offers Merge, Rebase and Abort (default Rebase).
An unchecked answer affects this invocation only. Don't show this message again
stores the selected answer under the original three OpenRebaseRemoteBranch keys,
including Yes/No and all three fast-forward answers, as upstream ShowCheck does.

A No or Abort retains the successful Fetch result and its Log/Reset/Fetch/Switch
actions. Rebase closes the owned result/options and opens the native plan with
the immutable fetched hash. A Git-configured rebase Pull uses automatic mode,
skips these questions, and forwards auto-start and preserve-merges. Diverged
branches proceed to the plan without a fast-forward question.

Merge executes a real --ff-only merge of that immutable target. Its successful
result closes automatically; failure stays in progress. A failure with working
tree conflicts offers Resolve, routed to native Commit as the upstream callback
does; a failure without conflicts offers no post-action. macOS uses the existing
owned progress sheet for this merge phase rather than another modal window.
Inputs, duplicate fetch/close and cancellation stay gated during an owned decision
sheet; subsequent transport uses the existing cancellation policy.

[Decision QA](qa/fetch-rebase-decisions-2026-10-08.json) records real equal, ahead,
diverged and fast-forward histories, held decision gates, retained Abort/No,
saved answers, automatic handoff, actual fast-forward mutation, dirty/conflicted
merge failures and captured retry. Ordinary Fetch/cancellation regressions also
run. The native presenter is wired but physical button/default/Escape/suppression
interaction and factory/editor acceptance remain unverified.

The earlier safety adaptation remains: fetchForRebase fetches the selected branch
explicitly and pins FETCH_HEAD immediately. Source DoFetch uses its conventional
remote-tracking ref. A custom refspec therefore does not make the native plan use
a stale conventional ref; the unchanged test uses the pre-fetch conventional hash
as upstream does. Native full remote chooser, empty-branch fallback/all-remotes
Rebase, libgit2 mode, failure after mutation, hook/credential/streaming and signed
sandbox acceptance remain pending. Full port and distribution remain incomplete.
