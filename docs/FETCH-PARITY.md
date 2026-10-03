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
Successful fetch closes and refreshes views; failures retain inputs.

## Evidence

Four real Git integration tests cover configured tracking-ref updates without
changing HEAD/index/worktree, three-state tags/prune overrides versus Git defaults,
remote branch browsing with Unicode names, URL fetch to FETCH_HEAD, shallow depth
1 then 2, all-remotes updates and invalid destination/depth/refspec requests.
The complete suite has 68 passing tests.

Native QA on the disposable documentation repository browsed preview-main from
its local bare remote and fetched it via URL. Tags cycled mixed → checked → unchecked.
A separate named-remote fetch populated the expected remote-tracking branch.
After both operations, HEAD and index/worktree patches matched their original
values byte-for-byte. Manage opened, selected the configured remote, displayed its
correct URL, and closed back to Fetch. A deliberately missing fixture URL showed
Git's error, retained its URL/branch, and allowed Cancel. `site/assets/fetch.png` is an actual capture.

## Remaining parity

- Launch Rebase After Fetch is present but disabled until the upstream interactive
  Rebase dialog, fast-forward choices and conflict recovery are ported.
- Full remote reference chooser hierarchy, tag selection and histories; the current
  chooser lists heads only. Full remote settings and their mutation/recovery QA.
- Submodule-specific default branch lookup, URL/branch histories, complete settings
  and window-size persistence.
- Streaming progress/cancellation, interactive credentials, network/SSH and signed
  sandbox runtime checks. Cancel is disabled while Git runs.
- Native shallow/depth, all-remotes, broader error recovery, keyboard, resize, light appearance
  and accessibility QA; integration tests alone do not establish those UI behaviors.
- Pull merge options are now native; interactive rebase and full recovery remain
  pending. See PULL-PARITY.md.

This shared source/resource remains partial; Fetch compilation and narrow verified
workflows do not establish full Pull/Fetch or App Store parity.
