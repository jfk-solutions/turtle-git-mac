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
literal server option containing spaces and punctuation. The current focused Push suite has eight passing tests, including read-only
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
- Full Browse References tree and selection-mode Log/RefLog source pickers.
- Full Remote Settings: multiple URLs, refspecs, proxy and advanced settings;
  partial configuration failures need recovery. Native Fetch QA opened the shared Manage sheet, read a selected remote
  and closed it; mutation/recovery interaction checks remain pending.
- History deletion/completion acceptance, local-reference history/chooser parity,
  complete preference and size persistence.
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
