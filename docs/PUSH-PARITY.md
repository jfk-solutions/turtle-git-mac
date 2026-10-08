# Push dialog parity

Reference: `PushDlg.cpp`, `IDD_PUSH`, PushCommand and `CAppUtils::DoPush/Push`
at the pinned commit in `upstream.json`.

The separate native window follows the upstream Ref, Destination and Options
order: all branches, editable local/remote references with browse buttons, named
remote or arbitrary URL, Manage, force with lease/force, tags, upstream tracking,
per-branch push defaults, submodule recursion and server push option. macOS uses
configured Git credential helpers and SSH agents rather than PuTTY key loading.
The original Push icon is used in the Log revision context menu.

## Implemented behavior

Branch defaults come from Git configuration; source changes reload those defaults.
Full tag identity is retained. Create Tag's Push checkbox opens this window with
only the new tag selected. Log Push opens it with the selected revision. Reference
browsers currently show searchable cached refs. Manage provides basic native remote
creation, removal, fetch URL and optional push URL editing.

Force with lease excludes Force and Include Tags. Upstream tracking and saved
push defaults have conditional enablement. Per-branch push settings are saved
before transport, like upstream, and remain set if transport fails. All branches
asks confirmation; an empty source asks confirmation for configured pushes or
remote deletion. All branches with tags uses separate branch and tag pushes.
All remotes reports completed destinations when a later destination fails.
Failures preserve the dialog; success closes it and refreshes repository views.

## Evidence

Six existing real Git integration tests cover named destinations/upstream configuration,
selected and renamed tags, commit hashes to new branches, all branches plus tags,
non-fast-forward rejection, stale and valid force-with-lease, partial all-remotes
failure, arbitrary paths, saved defaults, remote deletion, invalid input and a
literal server option containing spaces and punctuation. The current focused Push suite has ten passing tests, including read-only
submission validation and a pre-cancelled request that preserves remote refs and local config. Mixed staged/unstaged contents are preserved by push.

Native QA used only a disposable documentation repository and local bare remote.
The window pushed main to preview-main and set its upstream. Native Create Tag
created an annotated native-tag-push, opened Push with that full tag ref, and sent
only that tag. The remote contained only preview-main and native-tag-push;
other fixture tags were absent. Index and working-tree patches matched byte-for-byte.
Force-with-lease enablement was checked in the running window. Actual captures are
`site/assets/push.png` and the updated `site/assets/create-tag.png`.

## Remaining comparison work

- Streaming progress/separate progress-window layout, interactive authentication/signing, project
  hooks, and failure recovery across network transports.
- Full Browse References tree; physical Log/RefLog source-picker interaction and
  complete chooser parity. Selection-mode native Log/RefLog are now wired below.
- Full Remote Settings: multiple URLs, refspecs, proxy and advanced settings;
  partial configuration failures need recovery. Native Fetch QA opened the shared Manage sheet, read a selected remote
  and closed it; mutation/recovery interaction checks remain pending.
- History deletion/completion acceptance, local-reference history/chooser parity,
  remaining preference controls and size persistence.
- Native all-remotes/all-branches/deletion, submodule and server-option QA,
  keyboard, resize, light appearance and accessibility checks.
- Signed sandbox/App Store runtime and network credential access verification.

Transport Cancel now remains available while Push runs; see the cancellation
section below for exact scope and remaining acceptance.
Passing local tests and native branch/tag checks do not establish full Push parity.
The source and resource inventory therefore remain partial.


## Transport cancellation

Push now uses the shared ConfirmKillProcess preference (default false) shown on
the Dialogs settings page. With it enabled, Cancel asks the source question
**The process is still running. / Are you sure to abort?** with Yes as the default.
No leaves the operation running; Yes requests cancellation. The close gesture
uses the same model path and keeps the window until transport finishes. Inputs
remain disabled during transport; Cancel displays Cancelling… until the owned
process group stops. Failure/cancellation retains inputs, idle Cancel closes, and
a retry creates a fresh token. Cancelled operations do not trigger success.

This maps `CAppUtils::DoPush` and `CProgressDlg::OnCancel`. The source queues
separate commands for each remote and for branches/tags. Native cancellation
stops the current command and prevents later commands from starting. Reports
retain completed destinations/phases. Already-pushed refs and saved configuration
are not rolled back; cancellation after server mutation can leave effects that
require inspection. Pre-cancelled requests stop before settings are saved.

[Cancellation QA](qa/push-cancellation-2026-10-08.json) records a headless native
model with real owned wrapper/helper processes, an unrelated process, No/Yes
confirmation, retained inputs, no success callback and exact local HEAD/index.
It covers single-remote cancellation, cancellation after the first of two remotes
finishes, and cancellation of tags after branches finish. Completed bare-remote
refs remain; later refs are absent. Retrying each same model publishes the expected
refs and closes on success. These are model/Git checks, not physical sheets,
Cancel/Escape/window-close/default-button, layout/theme/accessibility or signed
sandbox acceptance. Streaming output, full progress/post-operation UI, project
hooks and network/authentication/signing parity remain incomplete.


## Repository-scoped editable histories and clipboard

Push now presents native editable dropdowns for destination URL, remote branch
and server push option. The source's `PushURLS`, `RemoteBranch` and `PushOption`
histories are scoped to the repository path, unlike shared Pull/Fetch history.
URL/option duplicate matching is case-sensitive and preserves exact UTF-16
spelling; destination duplicates match case-insensitively. Entries keep source
order, line-folding/trimming and the 26-save/25-load boundary from HistoryCombo.

History load fills the dropdowns but leaves URL and server-option text empty,
matching source LoadHistory's cleared selection. Destination load adds/selects
a configured push branch, keeping an existing duplicate's spelling. Source
changes reload its history/default; clearing the local source keeps the remote
destination for deletion and updates tracking enablement. Browsing inserts the
chosen destination into memory without saving. Selecting URL mode parses copied
`git pull` then `git fetch` text, as PushDlg does, or selects the latest saved URL.
The existing source parser retains its quote/offset/prefix quirks and native
POSIX/file-URL additions; copied `git push` is not recognized by this source path.
Selection does not execute Git or save history.

After confirmation and read-only option validation, ordinary submissions save
the destination history and save URL history only in URL mode, before transport.
Remote deletion (empty source with nonempty destination) and all-branch pushes
exclude URL/branch saving. Server-option history saves for all accepted forms.
Transport failures retain saved entries and input fields; invalid submissions
do not add history. Transport revalidates before writing config/executing Git.
Saving uses the submitted snapshot, so a queued field/default update cannot
replace its values during validation. History normalization does not rewrite the
actual server-option argument.

[History QA](qa/push-history-2026-10-08.json) records native-model URL and named
pushes, failed transport, invalid submission, confirmation and deletion/all-branch
exclusions, repository isolation, default/browse/case/ordering/limit behavior,
clipboard prefilling, exact local HEAD/index and a hidden native combo selection.
The cancellation matrix is also rerun against the new validation boundary. These
are headless model/Git/hidden-control checks; physical dropdown editing/completion,
Shift-Delete history removal, source locale trim/case equivalence, user pasteboard,
keyboard/theme/VoiceOver and signed sandbox acceptance remain pending. Full Push
and application parity remain incomplete.


## Remembered options and source submission questions

Push now remembers All Remotes per repository and restores it only while more
than one remote is available. An explicitly supplied source still overrides saved
All Branches; it does not clear All Remotes. The submodule-recursion dropdown
starts with `push.recurseSubmodules` unless a saved repository choice overrides it.
The source stores indices 0/1/2 for None/Check/On-demand; native preferences use
the same order. Absent or invalid native values fall back to Git config. Accepted
submissions save these choices before transport, including failed transport;
validation failure and an unanswered/No confirmation do not save them. URL mode
saves All Remotes false. Full source remote-selection/config-default behavior
and out-of-range registry equivalence are not established by this mapping.

Submission questions now use native Yes/No sheets and exact source text. All
Branches asks **Do you really want to push all local branches?**, defaults to No
and offers **Don't show this message again**. Empty source/destination asks the
source both-empty question with Yes as default. Empty source with a destination
asks the source remote-removal question, also defaulting to Yes, with warning
style. The all-branches suppression choice is app-wide (`PushAllBranches`),
matching the source remembered-answer scope. Source PushDlg explicitly remembers
Yes when No plus suppression is selected: that invocation stops, while later
all-branch submissions proceed without repeating the question. No suppression is
offered for deletion/both-empty.

[Preferences QA](qa/push-preferences-2026-10-08.json) records configured/saved
recursion precedence, repository isolation, multiple/single remote restoration,
explicit-source override, invalid-submission non-persistence, exact question
callbacks and No-with-suppression followed by a real successful all-branch push.
Real native NSAlerts are constructed without display to inspect Yes/No ordering,
return-key defaults, suppression text and deletion style, then closed. The four-Git
history matrix also runs against the new preference-save gate. Physical modal
interaction, Escape/default-button activation, sheet/window close, real submodule
recursion, accessibility/theme and signed sandbox acceptance remain pending.
Full Push and application parity remain incomplete.


## Short source branch/tag uniqueness

Submission validation now follows the exact reference lookup in
`CGit::IsBranchTagNameUnique`: it rejects a supplied short name when both
`refs/heads/<name>` and `refs/tags/<name>` exist. Revision resolution alone
can succeed with an ambiguity warning, so it is insufficient for this gate.
The native implementation uses exact `show-ref --verify --quiet` lookups rather
than relying on that warning or passing the ambiguous name to transport.
Rejection occurs before history/config saving and is shared by direct core Push.
Fully qualified references retain their branch/tag identity; the source check
forms refs from the supplied text and also permits such uncollided expressions.

[Source-validation QA](qa/push-source-validation-2026-10-08.json) records a real
branch/tag collision, read-only rejection, unchanged config and absent remote refs,
then qualified branch and tag pushes to separate expected ref namespaces. Native
models reject the short collision without saving any history or creating its
remote destination. The broader four-Git history workflow is also exercised.
Native initial/dropdown/browser local-branch selections now normalize to short
names; the source-presentation section below records their implementation and
remaining acceptance. Alternate upstream CLI suffix-pattern
lookup behavior, repository-access failures, physical controls and signed sandbox
acceptance remain pending. This does not establish complete Push validation or
application parity.


## Push source presentation and branch defaults

Initial/current local branches, supplied `refs/heads/` selections and browser
choices now use short branch names. Initial remote refs use `remotes/<remote>/…`,
matching PushDlg's initial stripping of `refs/`. Tags and commit/revision inputs
retain their supplied identity. The local dropdown lists branch/remote choices
and returns normalized names; selecting a branch that collides with a tag now
reaches the short-name validation gate rather than bypassing it with a qualified
ref. Manually entered qualified refs remain visible and retain their identity.

Normalization is opt-in for Push's use of the shared combo; Rebase continues to
receive its existing qualified refs. Push branch defaults now prefer an exact
local-branch lookup before revision resolution, so a same-named tag cannot mask
that branch's configured push remote/destination. Tracked merge refs use source
StripRefName behavior (`refs/heads/` removed, other `refs/` shortened), while an
explicit `pushbranch`, including Gerrit `refs/for/…`, is preserved.

[Presentation QA](qa/push-source-presentation-2026-10-08.json) records configured
defaults under a same-named tag, tracked-ref stripping/explicit destination
preservation, initial/browser branch normalization and rejection, retained tag/
hash identity and actual hidden native combo callbacks with normalization on/off.
The existing history/cancellation/preference matrices cover surrounding Git and
model workflows. Physical typing/dropdowns/browser/Log or RefLog selection, full
source default/remote-selection equivalence, resize/theme/accessibility and signed
sandbox acceptance remain pending. Full Push and application parity incomplete.


Push's URL, remote-destination and server-option dropdowns now offer immediate
history deletion with the shared native Shift+Delete receiver. See the deletion
section in FETCH-PARITY.md for source selection/persistence rules and remaining
physical popup/event-routing acceptance.


## Source selection from Log and RefLog

The local-source ellipsis now opens the source's three choices in order: Browse
References, Log, RefLog. Original repository-browser/Log artwork is reused in
these menu rows. Browse References keeps the existing head/tag picker and local
branch normalization. Log opens the existing native selection-mode Log scoped
to the current source (empty source uses normal HEAD defaults), with working-tree
rows hidden. RefLog opens the native HEAD reference log in selection mode,
matching the source default; its reference chooser remains available.

Accepting either picker copies the selected immutable commit hash into the local
source and reloads its push defaults/conditional controls. Cancel retains the
source. Selection does not save histories or execute Push; explicit OK still
validates and performs transport. The parent retains each picker and its existing
repository-access lease while the sheet is open; closing the child releases it.
Closing the parent also ends and closes its owned source picker windows.
Only one source sheet opens at once. Busy/all-branches/pending-confirmation model
gates prevent history-menu dispatch.

[Source-picker QA](qa/push-source-pickers-2026-10-08.json) records dispatch guards,
source-scoped actual history loading without working-tree rows, real Log and HEAD
RefLog selection callbacks, cancellation retention, hash control/default updates,
unchanged HEAD/index/config and no remote refs before OK. Explicit Push then
publishes the selected older commit while retaining local HEAD/index. These are
headless model/Git checks. Physical menu/sheet accept/Cancel/focus/resize/theme,
child/parent close lifecycle, full browser parity, accessibility and signed
sandbox lease execution remain pending. Full Push/application parity incomplete.


## Branch revision display

Dialogs settings now exposes upstream's Display branch revision number, default
off (`ShowBranchRevisionNumber`). Push snapshots it at submission. For each
successful destination in a single-source push, it appends the output of
`git rev-list --count --first-parent --end-of-options <source> --`, including tags
and revision expressions, as upstream DoPush does. All-branch pushes skip it.
The number is a display aid and is not a unique commit identifier. A count failure
after transport reports the destination as completed: published/deleted refs are
not rolled back. Empty-source deletion with this option can therefore succeed
remotely and then fail its count, matching the source command ordering.

[Counter QA](qa/branch-revision-number-2026-10-08.json) covers a merge whose total
count differs from its first-parent count, two destinations, disabled/all-branch
exclusion, count failure after deletion and native submission preference capture.
Native Log shows Branch RevNo next to the hash only for a single revision in its
first graph lane. It clears it on selection changes and captures the setting when
opening, like upstream. Native lane layout is an adaptation; full equivalence for
filtered/compressed/all-ref graphs remains pending. Log and Push physical setting,
interaction, appearance/accessibility and signed runtime acceptance remain pending.
Push's retained result/post-actions window, Request Pull and project hooks remain
unfinished; this setting does not establish full Push or application parity.
