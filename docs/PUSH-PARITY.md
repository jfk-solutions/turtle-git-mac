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

Six real Git integration tests cover named destinations/upstream configuration,
selected and renamed tags, commit hashes to new branches, all branches plus tags,
non-fast-forward rejection, stale and valid force-with-lease, partial all-remotes
failure, arbitrary paths, saved defaults, remote deletion, invalid input and a
literal server option containing spaces and punctuation. The full suite has 68
passing tests. Mixed staged/unstaged contents are preserved by push.

Native QA used only a disposable documentation repository and local bare remote.
The window pushed main to preview-main and set its upstream. Native Create Tag
created an annotated native-tag-push, opened Push with that full tag ref, and sent
only that tag. The remote contained only preview-main and native-tag-push;
other fixture tags were absent. Index and working-tree patches matched byte-for-byte.
Force-with-lease enablement was checked in the running window. Actual captures are
`site/assets/push.png` and the updated `site/assets/create-tag.png`.

## Remaining comparison work

- Streaming progress, cancellation, interactive authentication/signing, project
  hooks, and failure recovery across network transports.
- Full Browse References tree and selection-mode Log/RefLog source pickers.
- Full Remote Settings: multiple URLs, refspecs, proxy and advanced settings;
  partial configuration failures need recovery. Native Fetch QA opened the shared Manage sheet, read a selected remote
  and closed it; mutation/recovery interaction checks remain pending.
- URL/reference/server-option histories, complete preference and size persistence.
- Native all-remotes/all-branches/deletion, submodule and server-option QA,
  keyboard, resize, light appearance and accessibility checks.
- Signed sandbox/App Store runtime and network credential access verification.

The current operation waits for Git to finish; Cancel is disabled during transport.
Passing local tests and native branch/tag checks do not establish full Push parity.
The source and resource inventory therefore remain partial.
