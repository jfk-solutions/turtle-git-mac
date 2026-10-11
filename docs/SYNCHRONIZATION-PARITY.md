# Git Synchronization parity

Baseline: `7338078f8ddd924b8cddee35f512f2286072136d`, `SyncDlg.cpp`
(`FetchOutList`, `ShowInCommits`), its inline `AddDiffFileList` in `SyncDlg.h`,
and `Git.cpp::IsFastForward/GetCommitDiffList`, plus `BranchCombox.h`.
A partial native window now exposes the outgoing projection. This is not a
completed Synchronization dialog.

## Comparison backend

`GitRepository.synchronizationOutgoing` returns a pinned, read-only projection of
the local and remote-tracking revisions. Equal revisions produce Up to date with
no outgoing comparison. A missing remote branch produces the source unknown
branch state. The source's slash/backslash URL heuristic is retained: a typed URL
or path is unknown without contacting the server, even with Force enabled.

For a fast-forward push, the outgoing Log range is remote..local and the file
comparison is remote to local. Divergence without Force produces the blocked
state. Force keeps the remote..local Log range but compares files from the merge
base to local. The full history is requested, bypassing Log's ordinary 200-row
limit. File comparisons enable the source default 50-percent copy detection and
retain original paths. Existing other comparison callers keep their defaults.

An unusual pinned-source behavior is preserved: no merge base leaves a zero
CGitHash; GetCommitDiffList interprets zero as the working-copy revision. Forced
unrelated histories therefore keep outgoing commits and use working tree to local
for their file comparison. A forced behind branch can have zero outgoing commits
while still enabling Email Patch, just as the source does.

`synchronizationIncoming` compares the captured pre-operation revision with the
actual completed revision (HEAD after Pull, fetched upstream after Fetch), returning
that pinned comparison and old..new history. Equal revisions return empty lists.
Resolving hashes uses stdout independently of diagnostic output. Input NULs and
pre-cancelled operations are rejected; the token is forwarded through Git reads.
The snapshots do not authorize transport operations.

## Transport backend

`SynchronizationTransportOptions` and its immutable plan cover Pull, Fetch,
Fetch & Rebase, Fetch All, Remote Update, Prune, Push, Push Tags and Push Notes.
Pull, Fetch, Fetch All, Remote Update and Prune are wired to the native window.
Fetch & Rebase owns its source choices and separate progress. Push, Push tags
and Push notes now have native split actions and owned Shift Push options;
project pre/post-push hooks remain pending.

The source CLI rules are preserved: matching pull tracking omits an explicit
branch; configured Pull rebase performs Fetch and defers the native rebase
handoff. Branch-specific rebase overrides the global setting, including Git's
numeric and valueless boolean forms. `merges` requests preserved merges.
Existing tracking refs give Fetch a `branch:remotes/remote/branch` refspec;
missing refs and typed URLs use the selected branch alone. Fetch All omits the
branch for the selected remote. Remote Update uses `git remote update`; Prune
uses the selected remote. Git still applies its configured remote-update groups.

Push Tags includes both `--tags` and the selected branch refspec. Push Notes
uses `git notes get-ref` and ignores the destination-branch field. FETCH_HEAD
prefill uses exactly one for-merge line, preserving the source's FixBranchName
rule. An empty resulting source with a destination is a deletion refspec; the
executor requires separate explicit deletion authorization. NULs in fields or
metadata-derived arguments are rejected.

Pull requires explicit authorization before a planned branch switch. Git 2.39
rejects the pinned upstream's newer checkout `--end-of-options` syntax, so the
macOS adapter uses `switch --no-guess -- branch` for local branches and
`switch --detach -- revision` otherwise. Source old-HEAD metadata remains in the
original plan. Execution checks the repository identity and the Pull HEAD/branch
before work and again after asynchronous authentication. Cancellation reaches
metadata reads, checkout, authentication and transport; output uses the shared
stdout/stderr stream protocol. Fetch-for-Rebase pins the completed target hash;
if that read fails, a separate error retains the successful transport result.

Pull preflight predicts the selected branch's attachment, and detached targets skip
the native Fetch-for-Rebase interception. Pull resolves FETCH_HEAD as a normal
revision; Push alone uses the source unique-for-merge FixBranchName rule. After an
approved checkout and asynchronous key preparation, execution uses the actual
current branch's rebase setting and current pull configuration. This preserves
post-checkout hook and key-preparation configuration changes. The original plan
keeps its pre-checkout old HEAD for incoming results. `rebaseMode` and
`executedArguments` on the result report the command actually executed; owners
must use that mode for their native handoff rather than the earlier prediction.

The backend also exposes `synchronizationPullCheckout` and a continuation overload
of `synchronize`. The checkout step returns its own streamed command result and
an opaque checkpoint containing the original plan and the actual post-hook
HEAD/branch fingerprint. A native owner can present separate checkout progress,
then ask tracking questions and capture reference metadata before starting
transport. Continuation rejects a different repository actor or changed
HEAD/attachment and never repeats checkout, including when a hook selected
another branch. The existing combined executor remains available. The native
Pull owner now uses this checkpoint across its separate checkout progress and
tracking prompt.

Three additional Core tests exercise continuation after a branch-changing hook
with a different original baseline, streaming checkout output, no transport
before continuation, rejection of unapproved/cancelled checkout and foreign or
stale continuation, a no-switch Pull, and checkout blocked by uncommitted work.
The blocked checkout preserves the worktree, index and prior FETCH_HEAD and
returns no continuation checkpoint.

The native owner still needs Push project hooks, full conflict/reference menus,
the remaining source controls and complete post-action menus.
Native revision-expression prefill, metadata snapshot ordering after key loading
and broader repository modes also require further source parity work. No signed
or authenticated network acceptance claim follows from the local command tests.

## Native outgoing window

The TurtleGit menu opens a retained per-repository Git Synchronization window.
Local Branch, editable Remote Branch and Remote URL, Force, Outgoing Commits and
Outgoing Changes follow the source group order. Branch defaults use pull tracking
configuration independently of pushRemote/pushDefault/pushbranch. Selecting a
local branch reloads its tracking defaults. A detached HEAD still exposes the
local branch catalog so the user can select a branch. The local selector and
remote choices retain byte-distinct Unicode names rather than normalizing them.

The outgoing native table draws the existing colored graph before hash/message/
author/date columns. The changed-files tab shows Path, Extension, Status, Added
and Deleted, using original status artwork and appearance-aware status colors,
with original-icon comparison and unified-diff actions against the
pinned snapshot. Show Log and Commit use the captured repository and access
lease. Refresh replaces the outgoing snapshot and clears obsolete selection.

Each reload cancels its predecessor and checks identity before publishing. Close
invalidates owned reads; active comparison children and dirty editors guard
ordinary close. App Store reads require the retained repository grant. Quit
confirmation fences controls and comparison requests. Physical interaction,
complete source columns/context menus and displayed theme acceptance are pending.

## Native Fetch transport

The Fetch split control exposes Fetch, Fetch All, Remote Update and Cleanup stale
remote branches with original icons. The Command Log tab retains streamed output
in the shared selectable native text view, including its Copy/Copy All icon menu
and completion styling. Percentage/work text uses the shared Git output parser.
The Auto-load SSH key control captures a private transport coordinator per
operation; its passphrase sheet belongs to the synchronization window.

Controls and ordinary close are fenced while transport runs. Cancel honors
ConfirmKillProcess and uses a one-shot request identity; a reply after completion
or forced owner closure cannot cancel another request. Closing the owner cancels
its token, suppresses later publication and closes owned confirmation UI.
Completion refreshes the outgoing projection and the repository's other views,
including after cancellation or failure because Git may already have updated
references. Fetch does not populate incoming HEAD tabs. These four actions do not
run Pull/Push tracking questions or Push project hooks.

The Pull split control remembers its implemented selection per repository, using
the source entry indexes. Shift options routing, Compare Tags and
the other split controls remain to be ported. This does not establish complete
native Synchronization parity or authenticated network/physical/signed acceptance.

## Native Pull workflow

Pull captures the repository, selected fields, cancellation token and original
HEAD before any question. A selected branch change asks Switch/Abort and opens
separate owned checkout progress. Successful checkout closes that progress
automatically; failure retains selectable output until Close and prevents
transport. Cancellation honors ConfirmKillProcess. Forced owner closure cancels
checkout, dismisses its owned alert/progress and suppresses later publication.

For a typed non-URL remote and nonempty branch, a missing tracking branch asks
Yes/No/Cancel. Do not show again persists AskSetTrackedBranch=false even on
Cancel, as upstream does. Yes writes local remote/merge configuration for the
selected branch; No proceeds without writing it. Tracking is read after checkout.
The guarded checkpoint resumes transport without switching again.

Ordinary successful Pull fills pinned Incoming Commits with its graph and Incoming
Changes from original HEAD to completed HEAD. Equal hashes select Ref changes and
show an empty incoming log as Up to date. Failed transport checks conflicts using
a fresh cancellable read, selecting Conflicts or Command Log. Conflict rows route
Resolve to the captured repository. Incoming comparisons have an independent
owner and inherit close, dirty-document and Quit guards.

Configured Pull rebase executes Fetch, then uses the actual returned mode and
pinned target to open the existing Rebase controller as a sheet, with auto-start
and preserve-merges as appropriate. Its repository factory configures existing
conflict, commit-selection and completion actions. Incoming HEAD is read after
the child closes. An existing Rebase window is not reused for this operation, and
a modeless activation cannot replace an owned sheet's dismissal callback. Forced
parent closure detaches a busy Rebase to its retained repository owner, or closes
an idle child. Full physical child-dialog acceptance remains pending.

## Native Fetch & Rebase

The Pull split control exposes source entry 2, Fetch & Rebase, and remembers it
per repository. Successful transport pins the fetched target. The source
unchanged-remote check compares that target with the pre-fetch remote hash,
independently of current HEAD. No shows incoming results against the fetched
target without changing HEAD. Yes continues to the fast-forward check. The
shared prompt uses the source response values and suppression preference keys.

A fast-forward offers Merge/Rebase/Abort with Rebase as the default. Merge opens
separate owned progress for `git merge --ff-only -- PINNED_TARGET`. Its Core
state captures actual HEAD and branch attachment, and validates the same actor,
HEAD and branch before executing. Planning is read-only; later remote-ref movement
does not change the target. Equal HEAD/target remains a valid fast-forward.
Failure retains progress output until Close. Incoming HEAD and reference results
are read after the progress closes, including failed merge. Abort preserves
successful Fetch/reference results and does not fill incoming tabs.

Rebase opens the owned child without auto-start or preserve-merges. Divergence
opens it directly, without the standalone Fetch dialog's extra up-to-date prompt.
Incoming HEAD is read after dismissal. Configured Pull continues to request
auto-start and its actual preserve-merges setting. Checkout and Merge share the
same bounded selectable progress output, cancellation and force-close handling.
Full Merge post-actions and physical prompt/button acceptance remain pending.

## Reference-change results

The reference backend captures all refs into maps keyed by exact UTF-8 identity,
including symbolic remote aliases and annotated tags. Annotated tags retain the
source `^{}` friendly name and immediate tag target; nested tags are not silently
peeled through every tag layer. Git's [`object` header atom](https://git-scm.com/docs/git-for-each-ref)
provides that target without a separate process for every tag.

Comparison keeps full old/new hashes and first-line commit messages. New, deleted,
forward and rewind counts, divergent newer/older/equal committer times, unchanged
and unknown non-commit states follow `GitRefCompareList`. Backend metadata is
cached per object. Native results use the seven source columns, original reference
type tiles, header sorting and a persisted Hide unchanged refs header checkbox.
Row menus contain original icons for old/new Log, Compare and Reflog. Log/Compare
use captured hashes rather than resolving moving names.

The owner captures refs before transport, then reads results with a fresh token
so a cancelled Git command can still report changes it already made. Forced close
cancels the currently owned metadata read and suppresses later publication.
Non-integrating completion selects Ref changes after success, failure or ordinary
cancellation, as the source CLI flow does; Command Log remains available. Empty
filtered results show No differences found. Result-read failure retains the
successful/failed transport output separately.
Native factory handlers retain the repository and access lease.

Windows logical-sort policy, complete configured short-hash/column settings,
bisect short-name terms, Shift alternate Compare, actual downstream receiver
acceptance, large-repository performance, invalid UTF-8 refs, external writers,
physical input and signed/network acceptance remain to be checked. This is a
partial reference-result port rather than complete Synchronization parity.

## Verification scope

Five real-Git tests cover equal/ahead/missing/URL states, incoming and unchanged
results, pinned snapshots after a tracking reference moves, divergence/Force,
merge-base file scope, the unrelated working-copy fallback, copy identity,
205 outgoing commits, cancellation and invalid inputs. Staged/unstaged contents,
raw index and refs are preserved by the covered comparison cases. A sixth test
covers pull tracking versus push overrides, source ref-name stripping, missing
tracking configuration, detached HEAD, cancellation and byte-distinct packed refs.

The existing 15 revision-comparison regressions run alongside the new tests to
check the shared options change. Their fixtures use system Git; the five new tests
explicitly select the requested Git executable. No full-suite, transport, physical-input or signed-runtime acceptance claim
follows from them. The separate native verification covers only the outgoing
window controls/table/snapshot lifecycle; see the
[native QA record](qa/synchronization-window-2026-10-11.json).

Ten additional transport tests, alongside the six comparison/branch tests, pass
with system Git 2.50.1, Git 2.39.5 and packaged Git 2.55.0. They execute against
private local bare repositories and cover refspecs, force, tags/notes, checkout
authorization, FETCH_HEAD deletion refusal, asynchronous authentication cancellation
and pinned Rebase targets. Both unsigned build configurations and their bundle
audits pass. This does not verify native transport controls, real network
authentication, the full test suite or signed distribution; see the
[transport QA record](qa/synchronization-transport-2026-10-11.json).

The extended native receiver verifies the four Fetch actions against private local
servers using system and packaged Git, selectable command output, unchanged HEAD
and raw index, failed Fetch, pruning scope, cancellation choices, completed-request
late replies and forced-owner closure. Cancellation uses a controlled executable
shim; confirmation decisions are injected. SSH/network authentication and physical
input remain untested. See the
[native Fetch QA record](qa/synchronization-native-fetch-2026-10-11.json).

Two reference tests pass on system Git 2.50.1, Git 2.39.5 and packaged Git
2.55.0. The extended native receiver passes on system and packaged Git, including
all seven columns, actual icon menu dispatch to captured callbacks, Hide unchanged
persistence, failed/cancelled result selection and chained-operation ownership.
Both unsigned builds and bundle audits pass. Full-suite, downstream child windows,
rendered pixels, real network and signed acceptance remain unverified; see the
[reference-result QA record](qa/synchronization-reference-2026-10-11.json).

Five additional Pull preflight tests cover approved checkout hooks changing
configuration/attachment, asynchronous key-preparation configuration changes,
detached FETCH_HEAD/qualified refs and empty rebase branch validation after
checkout. All 23 synchronization tests pass on each of the three Git versions.
The existing native receiver passes against rebuilt Core on system and packaged
Git; both unsigned builds and bundle audits pass. This is backend preparation
for the pending native Pull workflow; see the
[Pull preflight QA record](qa/synchronization-pull-preflight-2026-10-11.json).

The separate-checkout checkpoint adds three tests. All 26 synchronization tests
pass on system Git 2.50.1, Git 2.39.5 and packaged Git 2.55.0. The existing native
receiver passes against rebuilt Core on system and packaged Git, and both
unsigned builds and bundle audits pass. The checkout API was backend-only at that checkpoint; the native Pull workflow
described above was added later. See the
[separate checkout QA record](qa/synchronization-checkout-2026-10-11.json).

The extended native Pull receiver passes on system Git 2.50.1 and packaged Git
2.55.0. It exercises actual separate checkout progress, the original incoming
baseline and graph/files tables, tracking Yes/No/Cancel suppression, branch Abort,
conflicts, failed-checkout Close and forced running-checkout cleanup with late
duplicate cancellation replies. The preserve-merges handoff is tested with an
injected completion callback; actual production Rebase child/replay acceptance
remains pending. Both unsigned configurations and bundle audits pass. Core source
is unchanged from the separate-checkout record; the full suite was not rerun.
Hidden bitmap captures omitted SwiftUI labels and were rejected for publication.
See the [native Pull QA record](qa/synchronization-pull-native-2026-10-11.json).

Fetch & Rebase adds two Core tests; all 28 synchronization tests pass on system
Git 2.50.1, Git 2.39.5 and packaged Git 2.55.0. The extended native receiver passes
on system and packaged Git, including actual separate Merge progress, unchanged
No/suppression with ahead HEAD, Abort, real owned Rebase controller fast-forward
and divergent replay, stale Merge refusal and pinned incoming results. Prompt
answers and Start/Close actions are injected; the child is opened in the callback
with the actual controller, not through the production RepositoryModel factory.
The temporary receiver embeds its framework rpath for the sequence-editor role.
System Git also completes a private two-commit replay using the actual Debug app
sequence editor without DYLD overrides. Both unsigned builds and bundle audits
pass. Full-suite, physical/rendered, full factory/completion and signed acceptance
remain unverified. See the
[Fetch & Rebase QA record](qa/synchronization-fetch-rebase-2026-10-11.json).

## Remaining full port

- Complete progress-phase arrangement and full history autocomplete/interaction acceptance.
  Tabs below the result grid, shared Force/SSH row and status/Close/Help footer
  now follow the source layout; full column and interaction parity remain partial.
  Owned branch choosers and Manage are implemented; physical acceptance is pending.
- Complete incoming/conflict/reference/outgoing column interactions, sorting and
  context menus. Actions, reference labels, conditional Bug-ID and shared dates
  now have focused native evidence; full visual/interaction parity remains partial.
- Project hooks, full completion actions, Shift alternative Compare behavior,
  authenticated/encrypted-key network acceptance and remaining transport variants.
- Physical keyboard/pointer/VoiceOver and production app/Finder workflow acceptance,
  including retained results, child ownership and cross-launch saved state.
- Configured similarity thresholds beyond the pinned default, libgit2 route
  equivalence, external writers and signed sandbox grants.
- Bare-repository app entry (currently disabled), signed Finder/App Store/distribution
  acceptance and complete application parity.

## Shift options routing

The Pull split control now samples Shift for the main button and menu commands.
Shift+Pull and Shift+Fetch open the full existing native options dialogs as owned
sheets. Other split entries remember their selection and return without starting
work, matching `CSyncDlg::OnBnClickedButtonPull` at the pinned source revision.
`synchronizationOptionsPlan` skips direct-transport rebase validation and returns
no executable command. Both synchronize overloads reject an options-only plan.
Pull first performs the existing approved branch checkout and tracking question.
The owner captures the original HEAD and references, prepares configured keys,
and waits for the options dialog to close before refreshing results. Full Pull
uses its own defaults. Full Fetch receives a named remote only; a typed URL in
Synchronization does not override the full Fetch defaults.

The options dialog owns its own progress, configuration and post-actions through
the existing application Fetch interaction configuration. After dismissal,
Synchronization reads reference changes and conflicts, then compares the
original HEAD against current HEAD when no conflicts exist, including Shift+Fetch
and a cancelled options dialog. Conflict results use the source resolve hint and
its `MergeConflictsNeedsCommit` suppression preference for both direct and
options-based Pull. Closing the owner forcibly invalidates and closes
the options dialog and its progress; late continuation results cannot update the
closed Synchronization model. Authenticated server, rendered/physical interactions
and signed sandbox acceptance remain pending. Because macOS uses private SSH
agents per operation, options transport also prepares its own configured agent;
this does not inherit a shared Pageant process as Windows does.

At checkpoint `5b472dd`, full-options Rebase closed Fetch before a modeless
Rebase callback, allowing incoming results to refresh too early. Synchronization
now installs an awaited owned-Rebase callback. It suspends the Fetch progress
and options sheets without invalidating their pending completion, opens Rebase
through the existing owned factory, then finishes the Fetch/options workflow
when Rebase dismisses. Original HEAD and the fetched target are retained.
Automatic Pull forwards auto-start and Preserve Merges; manual Fetch does not
auto-start. An opening failure closes suspended windows and propagates the
handoff error to Synchronization while preserving fetched reference changes.
The outgoing refresh retains that error; a normal manual Refresh clears it.

The standalone Fetch route retains its existing deferred callback when no owned
callback is installed. Full application factory/post-action acceptance, including
Push/Mail completion chains and the upstream TortoiseGit-specific stale-lock
marker prompt, remains pending. The marker prompt checks `tgitrebase.active`;
it must not be replaced by a generic Git active-Rebase test.

Verification at code checkpoint `5b472dd`: 29 synchronization tests passed on
system Git 2.50.1, Git 2.39.5 and packaged Git 2.55.0. The hidden native receiver
passed on system and packaged Git, including real options/progress and forced
running-Fetch cleanup. Debug and App Store unsigned builds, both bundle audits,
pin validation and site generation passed. The full suite was not rerun.
The [dated Shift options record](qa/synchronization-shift-options-2026-10-11.json)
retains exact source/log hashes and the earlier full-options Rebase completion gap.

Verification at code checkpoint `84d55b5`: the expanded native receiver passed
on system and packaged Git, including automatic Preserve Merges, real divergent
manual replay, cancellation, retained opening error/manual Refresh, suspended
window cleanup on failure/force-close and duplicate late dismissals. Both unsigned
builds and bundle audits, source pin validation and site generation passed.
Core/test source hashes are unchanged from the preceding 29-test-per-engine
checkpoint; Core tests and the full suite were not rerun in this GUI phase.
See the [owned Rebase record](qa/synchronization-owned-rebase-2026-10-11.json)
for exact source/log hashes and remaining acceptance work.

## Compare Tags backend

`synchronizationTags` implements the pinned `CGitTagCompareList::Fill` data
model using Git CLI remote advertisement rather than Windows libgit2. Rows
include raw annotated objects and `^{}` target entries,
with Same/Differ/Only local/Only remote states. Local nested annotation targets
remain one-level `git_tag_target` equivalents; remote advertisements retain
Git's recursive peeled target. Thus an equal nested tag object can have a
Different friendly row, as in the source. Commit messages are looked up only
in the local object database; absent remote objects, tags and non-commit objects
have empty messages. Comparing does not fetch objects or alter refs/index/config.
Default `remoteTags` consumers still omit peeled advertisement rows.

The immutable snapshot owns its repository actor and selected remote.
`synchronizeTag` normalizes a friendly row to the tag and implements non-force
Fetch, force Push, confirmed local deletion and confirmed remote deletion.
Local deletion uses an expected-object update-ref guard; actions that depend on
local tag state reject stale changes before and after asynchronous key loading.
Remote Push retains source force behavior; no server lease is added. Ref commands
disable macOS argument precomposition to preserve exact UTF-8 names.

At the backend checkpoint, the native Compare Tags entry, six-column table,
sort/hide state, icon menus, owned progress and result refresh remained pending. Backend
results are not a certification of native control parity. Broader symbolic tags,
short-name ambiguity, SHA-256 repositories, remote authentication, hook/race and
signed/rendered/physical acceptance also remain to be audited.

Verification at code checkpoint `daf20c0`: 34 focused tests passed on
system Git 2.50.1, Git 2.39.5 and packaged Git 2.55.0. Three new tests exercise
real tag advertisement and mutations, nested objects, read preservation,
confirmation, exact Unicode names, stale snapshots and cancellation. Existing
native Synchronization regressions passed six groups on system and packaged
Git with the rebuilt framework. Debug and App Store unsigned builds, both bundle
audits, pin validation and site generation passed. The full suite was not rerun;
there is no Compare Tags UI acceptance in this backend phase. See the
[backend verification record](qa/synchronization-tags-backend-2026-10-11.json)
for exact source/log hashes and remaining work.

## Native Compare Tags integration

The source Pull split entry at index 6 now opens a dedicated Compare Tags tab.
Its selection is remembered; Shift remembers the entry without starting work,
as for the other source entries above index 1. Loading owns a cancellable native
sheet, with repository-access checks and a captured remote. The tab has Tag,
Status, Local hash, Local message, Remote hash and Remote message columns.
Hashes display the pinned source's eight-character length with full-hash tooltips.
Names/messages use macOS natural ordering by default; header clicks select a
column/direction, and SortTagsReversed starts with descending tag names.
Windows Explorer's NoStrCmpLogical policy maps to a local preference. Exact-name
row identity is retained even when the platform collation treats names equally.

The header's Hide unchanged state initializes from TagCompareHideEqual and
stays in the window, matching the source header handler, which does not write
that registry value. Row menus offer local/remote Log, Compare revisions,
Fetch, Push, Delete local tag and Delete tag on remote according to source side
presence/difference rules. They use original artwork, including Commit for the
source tag Push icon, and honor the application context-icon setting. Native
Log and Compare route full selected hashes; displayed-prefix ambiguity is not
introduced into commands. Log selects the requested revision through the
production RepositoryModel callback.

Both deletion paths require a Yes/No answer for the normalized underlying tag
and captured remote. Fetch and Push own a separate output/progress sheet. Its
Close button completes the command handoff in manual mode; successful commands
with no post-actions also honor AutoCloseGitProgress modes 1 and 2. The table refills after dismissal,
including a failed/cancelled Fetch or Push. Failed remote deletion returns
without refill, as in source. Local deletion and its refill have no progress
window. Remote deletion and its refill use one compact native progress sheet.
Successful deletions refill. Repository log/status
views are notified after a command returns, since failure can still have changed
refs. Root force-close cancels the active operation, closes owned progress/key
prompts and fences late publication. Editing branch/remote controls returns to
the outgoing view and discards the old tag snapshot; Refresh in tag mode loads
tags again.

This remains partial parity. Physical/accessibility and rendered light/dark
acceptance, authenticated remotes, command-line close-on-end overrides and
cancellation/finish races, Shift alternative Compare routing, prefix-collision
behavior, Windows-versus-Mac
collation edge cases and wider symbolic/SHA-256/hook/external-writer scenarios
are still pending. No new screenshots or dialog certification are claimed.

Verification at code checkpoint `6408cc5`: seven hidden native check
groups passed on system Git 2.50.1 and packaged Git 2.55.0. The added tag group
exercises actual menu actions, real tag transport/deletion, source sort/hide
behavior, failed-command refill, preserved HEAD/index/config and forced parent
cleanup during loading/writing. Debug and App Store unsigned builds, both bundle
audits, inventory pin validation and site generation passed. Core/test hashes
match the backend record; Core tests and the full suite were not rerun in this
GUI phase. See the [native verification record](qa/synchronization-tags-native-2026-10-11.json)
for scope, source/log hashes, corrected fixture attempts and remaining work.

## Compare Tags source progress presentation

The first native checkpoint used the common output sheet for every mutation.
The source handlers distinguish them: Delete local tag calls DeleteRef and Fill
without a progress dialog; Delete tag on remote holds its compact system dialog
through DeleteRemoteRefs and Fill; Fetch/Push use CProgressDlg. The native port
now keeps these same phases. Compact sheets have no output pane or progress bar,
are not resizable, and do not reuse the saved regular ProgressDlg geometry.

Local deletion executes the guarded backend directly after confirmation. Its
remote advertisement refill uses the captured SSH factory without introducing
a command/loading sheet. Remote deletion performs its write and refill inside
one owned compact sheet, reusing the operation's SSH coordinator. Command failure
skips refill and preserves the previous snapshot. Successful deletion followed
by a failed refill clears the table and reports the read error. Loading and
remote-deletion errors close compact progress before presenting an owned native
error alert; force-closing the owner ends that alert and fences late completion.

Tag Fetch/Push now capture AutoCloseGitProgress when the output controller is
created. Manual mode retains output for Close; no-options and no-errors modes
close successful commands because these source tag handlers have no post-actions.
Failed commands retain output in every mode. A pending cancellation confirmation
still delays automatic close until answered. Existing checkout/merge automatic
close behavior is retained. The tag menu now uses the source caption Compare
with previous revision, and deletion confirmations use the source quoted-tag
question with the captured remote shown for remote deletion.

Rendered appearance, physical keyboard/mouse/accessibility, authentication,
command-line close-on-end overrides, cancellation/finish races, Shift alternative
Compare routing and wider object/ref/configuration cases remain pending.

At code checkpoint `e1b1f97`, all seven hidden native Synchronization groups
passed separately on system Git 2.50.1 and packaged Git 2.55.0. The extended tag
fixture checks inline local deletion, one compact remote deletion/refill,
rejected deletion preserving the old rows and reporting an error, manual and
automatic output closing, loading error handoff, and force-closing the actual
owned native error alert. Its rejection hook is explicitly pinned in the remote
receive command because the system local receiver read the client hook
configuration before entering the server. The temporary receive configuration
is removed before the unchanged-client-config assertion.

The first full invocation passed all system groups but then supplied a missing
Debug-bundle Git path; the corrected separate packaged invocation passed. Core
and test hashes still match the earlier backend record; no full suite was rerun.
See [progress presentation verification](qa/synchronization-tags-presentation-2026-10-11.json).

The unsigned Debug and App Store configurations built successfully; both bundle
audits, pinned-inventory checks and the website build passed. Post-run process
inspection found no test receiver/app/compiler processes. These checks verify
packaging, including the Finder extension and upstream icons, but do not establish
signed Finder registration, sandbox activation or App Store acceptance.

## Native Push split actions

The source Push button has three entries: Push, Push tags and Push notes. The
native footer now exposes those same choices with original icons and restores
source selection indexes 0/1/2. Normal actions capture local branch, remote URL,
destination and Force, stream into Command Log, read changed refs and refresh
outgoing results without checking out a branch or creating an incoming history.
Push tags retains the source combination of all tags plus the selected branch
refspec. Push notes uses Git's configured notes ref and ignores the destination.

Ordinary named-remote Push asks the existing Yes/No/Cancel tracking question
when the selected local branch has no tracked branch. Empty destination falls
back to the selected local branch. Yes writes remote/merge, No keeps Git config,
Cancel prevents transport; suppression is shared with Pull. Tags, notes and typed
URLs do not ask. Normal selection is persisted after accepted preflight. Remote
removal additionally requires an owned Yes/No confirmation before authorizing the
backend deletion; the pinned Windows Sync handler does not show this extra
question. Native project pre/post-push hooks are still unimplemented.

Shift+Push opens the full native Push options as an owned sheet with the source
local-branch preset; it does not preflight the Sync remote or overwrite the saved
split selection. Its own progress remains owned until Close, then Sync refreshes
refs/outgoing results. Production refresh and post-action routing reuse the same
configuration as standalone Push. Shift on Push tags/notes changes the displayed
selection but runs no command and writes no selection preference. Closing the
root invalidates and closes options/progress and cancels owned processes.

Full project hooks, authenticated network operations, physical/rendered/VoiceOver
acceptance, signed sandbox/Finder handoffs and complete Synchronization parity
remain pending. Hidden native checks are evidence for their exercised workflows,
not certification of the whole dialog.

Push verification uses its own preference suite, so a preceding Pull test's
tracking-suppression choice cannot affect the expected Push question. The fixture
also cancels an injected pending Shift options handoff before opening the real
owned sheet again; cancellation state resets on completion/new invocation. Root
invalidation clears transport/cancellation flags while cancelling the token and
closing all owned children.

The updated root window was captured and visually inspected in light/dark at
1050×660 and minimum 860×500 content sizes. The initial hidden-view cache omitted
SwiftUI layers; those images were discarded. Final captures use Core Graphics
on one actual native preview window, including window chrome, which closes after
all four captures. Duplicate split-control arrows were removed using the native
Menu arrow. Labels/actions fit at minimum size; later table columns require
horizontal scrolling. The two default-size captures are published on the site.
These captures establish this default root layout only, not menu/prompt/progress
rendering, keyboard/VoiceOver or complete source visual parity. Upstream's
[Sync manual](https://tortoisegit.org/docs/tortoisegit/tgit-dug-sync.html) and pinned
`doc/images/en/GitSync.png` were consulted; the missing controls and graph/actions/
refs/metadata column differences remain explicit backlog items. Shift source
resolution for FETCH_HEAD and broader special refs also needs further review.

At code checkpoint `e11f595`, the final full native run passed eight groups on
both system Git 2.50.1 and packaged Git 2.55.0. Only cosmetic split-menu labels
changed after that workflow run; fresh Debug build and final root captures
verified their rendering. Both unsigned configurations, bundle audits, pin checks
and website build pass. Core hashes match the prior backend record, without a
new Core/full-suite run. See [Push verification and limits](qa/synchronization-push-native-2026-10-11.json).


## Submodule split follow-up (October 11, 2026)

The native Synchronization footer now has Submodule Update, Submodule Init and
Submodule Sync, using the existing original Update/Add/Sync artwork. The pinned
`CSyncDlg::OnBnClickedButtonSubmodule` handler is the reference: normal Update
runs `git submodule update --init --recursive`, with `--force` only when checked;
Init runs `git submodule init`; Sync runs `git submodule sync --recursive`.
These commands ignore the dialog's remote/branch fields, retain Git's configured
update mode and leave Command Log selected without refilling Sync's result tabs.
The normal selected action is saved per repository.

Shift Update and Shift Init route to the existing standalone full Update dialog;
Shift Sync routes to standalone Sync. The production callbacks capture the
repository and access lease. As in the upstream separate-process launch, these
routes do not put Sync into a busy state or save its split selection. Standalone
Sync retains its own source non-recursive command; it is distinct from this
button's recursive normal action.

New real nested-repository Core checks cover Init without checkout, recursive
pinned child checkout and URL synchronization, dirty-work refusal/Force,
configured `update=none`, bare/unsafe metadata refusal and pre-cancellation.
The native fixture also exercises completion, saved selection, Shift routes and
forced-owner process cleanup. At code checkpoint `6d02bce`, the four new Core tests pass on system Git; the
38 focused Synchronization tests pass on Git 2.39.5 and packaged Git 2.55.0.
The focused native Submodule group passes on both system and packaged engines.
Both unsigned builds, bundle audits, inventory and website checks pass. Full
nine-group native regression, actual standalone Shift child lifetimes and new
button layout captures remain pending. The published root screenshots retain
the earlier Push checkpoint. See [verification and limits](qa/synchronization-submodule-native-2026-10-11.json).
This addition does not certify the whole dialog.


## Submodule lifecycle and layout follow-up (October 11, 2026)

The full Synchronization native receiver now passes nine groups on both system
Git 2.50.1 and packaged Git 2.55.0. In addition to the earlier direct-command
checks, Shift Init opens an actual standalone Update options controller with
saved settings, which survives closing Synchronization. Submitting it opens
actual standalone Update progress and completes successfully. A running
standalone Sync likewise survives its parent closing; closing its own window
reaps the Git process and prevents a late completion callback. These are real
controllers with fixture-injected callbacks/private preferences. The production
RepositoryModel routing is compiled and inspected, but its complete workspace
callbacks are not driven end-to-end by this receiver.

After that workflow run, the only application change was presentation of the
history graph column: it starts compact and expands to fit rendered lane widths.
Fresh Debug compilation and real native captures cover that change. The capture
fixture now includes a branch and merge, displaying colored lanes. All four
captures (light/dark, default/minimum size) were inspected; actions fit and the
graph is visible. The default-size captures replace the site images. Later
metadata columns still require horizontal scrolling at smaller widths.

The source screenshot still has action/ref/bug columns, two action rows and
other controls absent from this partial port. Displayed split menus, physical
keyboard/VoiceOver interaction and signed sandbox/Finder acceptance remain
pending. The Core and test hashes match the preceding Submodule checkpoint;
no new Core/full-suite run is claimed for this lifecycle/presentation follow-up.

At code checkpoint `18a07c1`, both unsigned builds, bundle audits, inventory
and website checks pass. See [lifecycle and layout verification](qa/synchronization-submodule-lifecycle-2026-10-11.json).


## Stash split follow-up (October 11, 2026)

The native footer now uses two action rows, with Stash changes/Pop/Apply beside
Show log and Commit, following the pinned SyncDlg arrangement. Normal commands
are `git stash save`, `git stash pop` and `git stash apply`. They ignore remote
and Force fields and do not use the full Save dialog's optional message,
untracked/all or follow-up settings. Whole-project Save retains Git's internal
magic pathspec semantics so tracked work is actually cleaned; untracked files
remain. Apply retains the stash. Pop drops it only after successful application;
neither requests index restoration.

The commands leave outgoing/reference results unchanged and hide incoming
results. Failed Pop/Apply checks actual unmerged entries and selects Conflicts
only when they exist; otherwise Command Log remains selected. Conflict-check
errors retain the original command output and append the inspection error.
Shift Save routes to the existing standalone Save dialog for the captured
repository/access lease. Shift Pop/Apply do nothing. Source does not save a
Stash split index, so reopening starts with Save.

Three real-repository Core tests pass on system Git 2.50.1, Git 2.39.5 and
packaged Git 2.55.0. The focused native Stash receiver passes on system and
packaged engines, including conflict-tab selection, Shift routes/no-ops,
closed-owner fencing and forced process reaping. Actual Shift Save child
lifetimes and the full ten-group native regression remain pending. No full-suite
claim is made. Four root captures were inspected: original colored icons,
compact merge graph and both footer rows fit in both themes/default and minimum
sizes. The default captures replace the site images; menus/progress/conflicts
are not certified by these root captures. Full source controls/columns,
workspace callbacks, physical/VoiceOver and signed acceptance remain pending.

At code checkpoint `1afffb2`, both unsigned builds, bundle audits, inventory
and website checks pass. See [Stash verification and limits](qa/synchronization-stash-native-2026-10-11.json).


## Stash standalone lifetime follow-up (October 11, 2026)

The standalone Stash Save options window now owns cancellation and closure of
its progress sheet when forcibly closed. Previously, invalidating options did
not cancel its active progress model or close the attached sheet. Progress now
refuses late results/completion actions after invalidation, and the options
model refuses late completion/confirmation callbacks. Ordinary completion and
its selected post-action still finish before releasing the options window.
Closing Synchronization leaves the separately launched Save window alive.

The options controller accepts private preferences for verification and passes
them into its progress model and untracked-warning suppression. Production
callers retain their standard preferences. Hidden options also keep their
progress sheet hidden. The expanded receiver opens actual Shift Save options,
closes Sync, submits a captured message, exercises a completion action, and
force-closes a separately blocked options/progress pair to check process reaping,
sheet detachment and absence of late replies. It also injects command/status
failures to check that conflict-inspection errors preserve original command
output and leave Command Log selected. Production workspace callbacks and
physical/signed acceptance remain separate.

At code checkpoint `e57e137`, all ten Synchronization groups and the existing
Stash Save model checks pass on both system and packaged engines. Both unsigned
builds, bundle audits, inventory and website checks pass. The backend's before/
after `refs/stash` reads still need cancellation-token propagation and separate
process-reaping checks; this phase checks the blocked main stash command only.
See [verification and limits](qa/synchronization-stash-lifecycle-2026-10-11.json).


## Stash reference-read cancellation follow-up (October 11, 2026)

Stash Save now passes its cancellation token into both before/after
`refs/stash` inspections and checks cancellation after each optional read.
An absent stash still permits Save, while cancellation is no longer swallowed
by `try?` or reported as successful completion. Cancellation before the write
preserves the working file/index and stash reference. Cancellation during final
inspection preserves any stash already created; it does not undo that write.

A controlled wrapper stalls each reference-read phase around a real Git save.
Core checks verify process reaping, preserved HEAD, untouched pre-save work and
retained post-save stash content. Native checks force-close options during the
first read and ordinarily cancel progress during the second. Closed options
suppress late replies; ordinary post-save cancellation shows Cancelled, offers
no completion actions and closes cleanly while retaining the created stash.
This addresses the reference-read gap recorded by the preceding lifecycle
checkpoint. Broader UI/physical/signed acceptance remains separate.

Focused checks passed on system Git 2.50.1, Git 2.39.5 and packaged Git
2.55.0; native Stash checks passed on system and packaged Git. Both unsigned
builds and bundle audits passed. See [verification scope and limits](qa/stash-reference-cancellation-2026-10-11.json).

## Manage Remote settings (October 11, 2026)

The source `OnBnClickedButtonManage` opens Settings on its Remote page modally,
then calls `Refresh` after dismissal. The native Manage button now sits beside
Remote URL and opens the existing native Remote settings page as an owned sheet,
using the captured repository, access lease and private/default preferences.
It reuses configured Fetch interactions for the settings page's Fetch offer.
The settings page blocks Sync transport/reload and normal parent closure.
Dismissal reloads the remote/branch catalog and outgoing projection while
retaining typed local/remote branch, URL and Force values. Forced parent closure
invalidates both models, cancels settings reads and closes the owned sheet.

The native page is currently a standalone Remote settings sheet rather than
the upstream full Settings tree. The complete Settings tree, physical button/keyboard
acceptance and signed sandbox acceptance remain pending.

Focused all-source Manage checks and the eleven-group native regression passed
with system and packaged Git. Debug and universal unsigned AppStore builds,
bundle audits, inventory and site checks passed. Updated native light/dark
screenshots are published; both sizes were inspected against the source. See
[verification methods and limits](qa/synchronization-manage-native-2026-10-11.json).

## Selected remote fallback after Manage (October 11, 2026)

Source Refresh captures the combo selection index and text before rebuilding
history/remotes. If the index was nonnegative and that text is no longer a named
remote, it chooses the first rebuilt entry. Typed text survives. Native Sync now
tracks user selection versus typing through the shared combo delegate, and uses
that distinction on Manage dismissal and ordinary Refresh. Local/remote branch
text and Force remain unchanged. Refresh reloads the URL history before choosing
a fallback; a history URL selected from the menu follows the same source rule.
Programmatic combo redraw does not turn typed text into a user selection.

The focused native regression removes a selected remote through the actual owned
settings sheet, verifies fallback, then verifies that typed text with the same
name survives dismissal. It also exercises history reload and selected URL
fallback through Refresh. Physical input and the full Settings tree are separate
remaining requirements.

Focused native checks passed with system and packaged Git, along with unsigned
Debug/universal AppStore builds, bundle audits, inventory and site checks. See
[verification scope and limits](qa/synchronization-selection-native-2026-10-11.json).

## Local and remote branch browse buttons (October 11, 2026)

Sync now has both ellipsis buttons in the source positions after their branch
fields. The inherited BranchCombox handlers use a local-head-only reference
picker for Local Branch and a remote-reference-only picker for Remote Branch.
Local acceptance strips refs/heads/ and reloads the selected branch's tracking
remote/branch. Remote acceptance strips refs/remotes/, splits at the first slash,
sets the remote and remaining branch text, adds the branch to the in-memory
history, and reloads outgoing results. Force remains unchanged. Cancel returns
without altering the fields or reloading Sync.

Each picker is the existing native Browse References dialog, presented as an
owned sheet with captured repository access and preferences. The production
workspace configures its reference actions through the shared browser adapter.
While it is open, duplicate pickers, Manage and parent transport/normal closure
are blocked. Forced parent closure invalidates Sync, abandons picker completion,
ends its sheet and cancels the browser's reader. The complete picker menus,
physical input/accessibility and signed scope remain separate acceptance work.

Twenty Core reference-browser tests passed on system Git; the namespace/tracking
check also passed on packaged Git. Focused native branch-picker checks passed
with both engines. Unsigned Debug/universal AppStore builds, bundle audits,
inventory and site checks passed. All four native root captures were inspected
against the source; updated full-size captures are published. See
[verification scope and remaining work](qa/synchronization-branch-picker-native-2026-10-11.json).

## Apply Patch caller audit and prerequisite (October 11, 2026)

Sync OnBnClickedButtonApply captures HEAD, opens CImportPatchDlg and only
inspects incoming/outgoing results after IDOK. ImportPatchDlg's OK handler
clears m_PathList; its worker applies checked files using the selected options.
The normal completed return therefore must not import the same patches again.
The native importer now distinguishes final OK from Cancel and cancels owned
Git work on forced closure. The native Sync button now opens the captured importer as an owned sheet.
Only final OK refreshes incoming results, without importing files a second time.
The file comparison uses HEAD captured immediately before opening the dialog;
the incoming log uses the previous Pull/Fetch baseline when available. Without
a prior transport, the native log uses the immediate pre-import HEAD.

The source-position Apply Patch button retains the upstream patch artwork.
Cancel preserves Sync results; a skipped/no-change session shows the source
“No commits get from patch” result and hides the Incoming Changes tab. Changed
HEAD refreshes outgoing results while preserving Force. Parent/duplicate-command
guards, sheet dismissal and forced parent cleanup have focused native verification
with both system and packaged Git. A missing HEAD reports an error before opening
the importer. The full 13-group Sync native regression passed on each engine (26 groups).
The standalone Import Patch regression also passed all 24 groups per engine
(48 groups). Actual light/dark captures at normal and minimum sizes were
inspected against the pinned GitSync image; Apply Patch fits in both sizes.
The refreshed normal captures are on the website. Debug and unsigned universal
App Store builds, both bundle audits, inventory-pin and site checks passed.
Physical input and signed acceptance remain unverified. See [Import Patch lifetime work](IMPORT-PATCH-PARITY.md) and the
[checkpoint evidence](qa/synchronization-apply-native-2026-10-11.json).


## Email Patch caller audit and export prerequisite (October 11, 2026)

SyncDlg::OnBnClickedButtonEmail reads the current local branch, trims remote URL
and remote branch, then runs `format-patch -o <repository> --end-of-options
<remote>/<branch>..<local>`. It does not open Format Patch options or use their
saved no-prefix/output-directory preferences. FixBranchName handles FETCH_HEAD
by selecting the sole for-merge record. CAppUtils::SendPatchMail opens Send Mail
options and then mail progress; an empty export shows a no-patches message.

FetchOutList disables Email Patch for unknown URL/branch, equal hashes, and
divergence without Force. Fast-forward/Force enables it even when an unequal
but behind local branch yields no outgoing patches. The Core projection already
exposes that gate through canEmailPatch.

The new Core synchronizationEmailPatches method exports this captured range
into the repository using the existing safe argument-vector/format-patch route.
At the export prerequisite checkpoint, the native button, no-patches/error
presentation, mail grants and owned sheets were pending. The native follow-up
below records that work separately; the backend tests alone do not establish
operational or visual parity for the Email Patch control.

Two focused real-Git tests passed with system Git 2.50.1 and packaged Git 2.55.0.
They verify actual subjects from a selected branch while HEAD points elsewhere,
unchanged HEAD/refs/index/config, sole/ambiguous FETCH_HEAD, empty ranges,
pre-cancellation and missing branches. See [export prerequisite evidence and
corrected attempts](qa/synchronization-email-core-2026-10-11.json).


### Native Email Patch handoff verification

The native source-position button now uses original menusendmail artwork and
the outgoing canEmailPatch gate. It exports directly to the repository, then
opens captured native Send Mail options and progress as owned sheets. Options
detach before progress opens; Cancel and result dismissal release the parent
guard. The parent retains no-patches/export-error alerts. Forced closure cancels
owned export/sender work, ends child prompts/sheets and suppresses late workflow
submission/completion. Generated patch files remain in the repository, as upstream.

Focused native checks passed with system and packaged Git, including two actual
patch subjects, options Cancel, captured configured mail settings, error-progress
dismissal without public delivery, unknown/behind gates, Force with an empty-range
alert, unchanged HEAD/refs/index/config, duplicate/Quit guards and forced export
and sender Git/process-group cleanup. The expanded fixture verifies the equal-hash disabled gate. The full 14-group
Sync fixture passed on each engine (28 groups), before the final cancellation-
confirmation state cleanup. The final focused fixture passed on both engines
with an actual pending Abort sheet, cleared active state, detached prompt and
reaped Git/process group. Debug and unsigned universal App Store builds, both
bundle audits, inventory-pin and site checks passed. Actual normal/minimum
light/dark captures were inspected; both patch buttons fit, and normal captures
are on the website. See [native checkpoint evidence](qa/synchronization-email-native-2026-10-11.json). Public delivery,
physical input, signed grants and full dialog certification remain unverified.

## Source layout follow-up, 11 October 2026

The result tabs now sit below the grid, in the source order and with the original
Log/In Commits/In Changelist/Out Commits/Out Changelist/Ref List captions.
Conditional Conflicts and Compare tags retain their existing modes. Force shares
the SSH row, and Close/Cancel and Help now sit beside the status footer. Help
routes to the official Synchronization manual; physical browser handoff remains
unverified. Native Refresh remains available.

The final Debug and unsigned universal AppStore builds and both bundle audits
passed. Six actual normal/minimum/incoming-tab light/dark captures were inspected
against the pinned upstream screenshot and resources; the compact captions fit.
Private refs/index/config were preserved, the owned window closed and receiver
reaped. Normal captures refresh the website. This UI-only follow-up does not claim
a new full behavioral suite run or complete dialog parity. Source columns, date
formatting, history, menus, progress phases and signed/physical acceptance remain
open. See the [verification record](qa/synchronization-layout-order-2026-10-11.json).

## Saved history follow-up, 11 October 2026

Accepted Close now saves remote branch and URL histories, following SyncDlg::OnOK
and CBranchCombox::SaveHistory. Forced teardown does not insert typed values.
Configured remotes append after saved URLs on initial/Manage reload; ordinary
field refresh preserves deletions and list order. Remote branch history retains
the source case-insensitive 25-load/26-save rule. URLs compare exact UTF-16 and
use Sync's effectively unbounded history limit. Both controls fold CR/LF and trim
source whitespace. Shift+Delete in an enabled open popup removes its selected
item immediately, persists without waiting for Close and chooses the next or
previous item. Deletion remains available during read-only refresh.

The focused native Close/reopen, blocked/forced-close, popup deletion, ordering,
case/Unicode, repository isolation and Git-state checks passed with system and
packaged Git. Existing Pull/Fetch history workflows also passed with both engines
after parameterizing the shared helper's limit. Receivers were run serially and
reaped. These are receiver checks; physical popup/VoiceOver, native path/URL
autocomplete and signed acceptance remain open.

A broader full Sync regression did not complete at this history checkpoint.
The system-Git receiver was sampled in Foundation Process.waitUntilExit and then
stopped and reaped too soon. Later healthy samples demonstrated that these
intermittent waits and gaps between child processes do not establish a deadlock.
That earlier run remains incomplete; the subsequent process-completion follow-up
uses phase progress and a realistic fixture deadline to verify completion.

Debug and unsigned universal AppStore builds, both bundle audits and the inventory
pin check passed. No new layout screenshots or dialog certification are claimed.
See the [verification and diagnostic record](qa/synchronization-history-native-2026-10-11.json).

Diagnostic correction: subsequent healthy Core Rebase samples also show brief
process-exit waits and gaps between children. The earlier snapshot did not prove
a deadlock; that receiver was stopped too soon. Its run remains incomplete. The
follow-up removes Foundation notifications from ordinary Git completion and must
be assessed using completed workflows, not a claimed proven root cause.

## Ordinary process completion follow-up, 11 October 2026

Ordinary Git commands now share the descriptor/environment/spawn code of the
cancellable runner and block on their own PID, preserving normal signal exit
status. The real Foundation process-group baseline confirms that both runners
create an independent child group. This is an implementation change; no proven
Foundation deadlock root cause is claimed.

All 72 selected Core tests passed, including 55 Rebase cases. Owned Shift Rebase
and measured Fetch/Rebase fixtures passed with system and packaged Git. The
concrete native failure was an outer ten-second fixture deadline covering Fetch,
owned child load/replay and result refresh. The success assertions are unchanged;
the standard fixture now has a monotonic 60-second state deadline, explicit phase
markers and a bounded 1200-second receiver lifetime. Debug and unsigned universal
AppStore builds and both bundle audits passed. The complete native regression has
passed all 28 groups across system and packaged Git; both receivers were reaped.
The inventory pin audit and documentation-site build passed. The complete Core
suite passed 979 tests with one optional DNS probe skipped and no failures. See the [verification record](qa/git-process-exit-2026-10-11.json).

## Revision lists, 11 October 2026

Pinned `SyncDlg.cpp::OnInitDialog` calls `GitLogListBase::InsertGitColumn` for
both SyncIn and SyncOut. The native lists now show Graph, Actions, Message,
Author and Date by default. SHA-1, email and committer columns are optional;
Bug-ID appears only for configured issue properties. Each list has independent
visibility preferences, a header menu and reset; saved native width/order layouts
use a new version to avoid the previous always-visible Hash arrangement.

Actions use the original five fixed icon slots and a serialized, cancellable
all-parent Git read. Busy transitions and owner invalidation cancel the reader;
closed/generation checks fence late results. Messages use the existing native
Log badge painter, including current/local refs, tracking outlines and annotated
tag tips, theme-aware source colors and optional symbolic upstream markers.
Date, relative-date tooltips, log font, full message and left/right label settings
use the same preference keys as Log.

The focused native fixture passed with system and packaged Git. It checks real
added/modified/deleted/renamed paths, annotated/current/tracking labels, issue IDs,
date/message settings, independent header preferences/reset, immutable Git state,
and owned slow-query termination with late-result suppression. Sixteen actual
outgoing/incoming normal/minimum light/dark images were captured across the two
engines. Debug and unsigned universal AppStore builds and both bundle audits passed.
All 28 broader Sync regression groups passed on code 5e5fc0e with both owned
receivers reaped; transient SwiftUI cycle warnings remain an investigation item.
The complete Core suite passed 979 tests with one optional DNS probe skipped and
no failures, on unchanged Core sources from the process-completion checkpoint.
This evidence covers revision-list code 5e5fc0e; later clipboard changes have a
separate record. Full row/context interactions, SVN/ID
special modes, custom bisect terms, physical accessibility and signed acceptance
remain open. See [the verification record](qa/synchronization-revision-list-2026-10-11.json).

## Clipboard menus and selection retention, 11 October 2026

The incoming/outgoing revision lists now expose the source clipboard submenu:
full details with/without changed paths, hashes, full authors, author names/emails,
subjects/messages, and tag/branch names. Right-clicking a painted label carries
its canonical name; multiple-row menus capture their ordered revision values.
Full details reuse the cancellable all-parent/notes/annotated-tag Core routine.
Forced closure cancels the owned read and fences late clipboard writes. List
refresh now restores selected commit hashes, fixing the selection loss reproduced
between two consecutive full-detail copy actions. Installing the shared badge
cell before setting its font also preserves HEAD's bold message text.

Both Git engines passed the expanded native fixture, including private clipboard
contents, captured multi-selection, source text formats, pointed names, metadata
with/without paths, selection retention, and owned read termination without late
publication. Debug/unsigned universal AppStore builds and both audits passed.
The complete Core suite passed 979 cases with one optional DNS skip; the skipped
system MX probe subsequently passed, including 32 post-open descriptor checks.
Six actual normal/minimum/incoming light/dark demo captures were generated and
the two normal public-site images updated after inspection. Full row/context
commands beyond clipboard, cross-launch/tab selection, live font sizing, source
special modes, physical/signed acceptance and the prior transient cycle warnings
remain open. See [the clipboard record](qa/synchronization-clipboard-2026-10-11.json).
