# Clean port

The Clean workflow is incomplete. There is no native Clean dialog or Finder Clean
route yet. Core preview and accepted-plan execution are implemented; native
confirmation/progress and submodule traversal remain unported.

## Pinned behavior

At upstream commit `7338078f8ddd924b8cddee35f512f2286072136d`,
`CleanTypeDlg.cpp` and `IDD_CLEAN` provide three radio choices: all untracked files
(`-fx`), non-ignored untracked files (`-f`) and ignored files (`-fX`). Directory
removal defaults on and is remembered per repository together with the type.
Disabling directories clears the additional force switch for unmanaged nested
repositories. Dry run and Submodules default off. Trash is the default unless
`RevertWithRecycleBin` disables it.

`Commands/CleanupCommand.cpp` adds `-n` for dry runs and Trash planning. It cleans
selected folders (or file selections’ containing folders), optionally traverses
initialized submodules, and exposes Retry plus Trash/permanent-delete actions after
a successful dry run. Those execution/progress/confirmation behaviors still need
native implementations.

## Current Core reader

`GitRepository.cleanPreview` runs only `git clean -n` with literal argument-array
scopes, optional directory removal and the selected type. A second force flag
permits previewing unmanaged nested repositories only when directories are enabled.
Its default is all types with directory removal and nested-repository protection,
matching the dialog’s initial choices. The caller must adapt Finder file selections
to containing directories; this low-level reader accepts literal scopes directly.

The reader forces quoted Git output without changing saved config and decodes
C-style escapes and octal UTF-8 filename bytes. It retains raw output and candidate
order, including trailing directory slashes. Skipped-repository messages are not
candidates. Absolute/escaping/admin-directory scopes, bare repositories, canceled
reads and unrecognized or invalid-UTF-8 candidate names fail. No files are removed.
Optional index locking is disabled for the read.

Real-Git tests cover all three modes, directories, a protected nested repository,
explicit unmanaged preview, ignored files, Unicode/newline/quote/backslash names,
pathspec-looking literal names, `core.quotepath=false`, cancellation and rejected
scopes/bare repositories. They compare exact HEAD, index, config and working-file
bytes. See [the preview QA record](qa/clean-preview-2026-10-07.json).

## Accepted-plan execution

`executeClean` defaults to Trash; permanent deletion requires an explicit choice
from the caller. Native callers must confirm the action and retain repository
access. The preview captures SHA-256 content fingerprints and filesystem metadata
for regular files, directory trees and symlink targets without following links.
Execution refuses a foreign repository plan, takes an exclusive index lock, and
reruns the preview before removing any candidate. Changes in candidate paths,
tracking state or directory contents require a new preview. Each candidate is
rechecked immediately before removal. HEAD and index contents are never written.

Trash failure never falls back to permanent deletion. Cancellation and removal
errors return completed paths, recovered Trash URLs and the path where cleanup
stopped. Completed permanent deletions cannot be rolled back. Filesystem checks
and removal remain separate operations; this is not an atomic filesystem snapshot.
Recursive fingerprints read candidate contents in cancellable 64 KiB chunks and
can add substantial work for large cleanup folders. Non-UTF-8 names and special
file types currently fail instead of being removed.

Six real-Git tests include actual recoverable Trash of binary files, directories
and an outside-target symlink, selective permanent ignored-file cleanup, explicit
unmanaged-repository removal, changed folder contents/newly tracked paths, foreign
plans, owned preexisting lock preservation, pre/mid-operation cancellation and an
injected Trash failure without deletion fallback. Owned Trash items are removed
after their recovered contents are checked. See
[the execution QA record](qa/clean-execution-2026-10-07.json).

## Remaining work

- Native resource-matching controls and per-repository option persistence.
- Finder/main-app command routing and file-to-directory scope adaptation.
- Initialized submodule traversal with access leases and recursive scope rules.
- Native confirmation and progress around Core execution, Retry and dry-run
  post-actions; operation progress/cancellation UI and signed Trash acceptance.
- Displayed light/dark layout, original icons, keyboard/VoiceOver and signed sandbox
  acceptance. The Core checks do not establish native dialog parity.
