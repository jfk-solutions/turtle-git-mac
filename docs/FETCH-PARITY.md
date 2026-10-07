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

Nine real Git integration tests cover configured tracking-ref updates without
changing HEAD/index/worktree, three-state tags/prune overrides versus Git defaults,
remote branch browsing with Unicode names, URL fetch to FETCH_HEAD, shallow depth
1 then 2, all-remotes updates and invalid destination/depth/refspec requests.
Two additional Fetch/Rebase tests verify a pinned fetched branch, dirty-worktree
preservation, replay ancestry and active-session rejection. The current focused
Pull/Fetch tests passed all 17 checks within the 20-test run that also covers
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
  fast-forward choices, post-operation actions and full conflict recovery remain.
- Full remote reference chooser hierarchy, tag selection and histories; the current
  chooser lists heads only. Full remote settings and their mutation/recovery QA.
- History deletion, complete settings
  and window-size persistence.
- Streaming progress/cancellation, interactive credentials, network/SSH and signed
  sandbox runtime checks. Cancel is disabled while Git runs.
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
history deletion and signed sandbox checks remain pending. Full port incomplete.
