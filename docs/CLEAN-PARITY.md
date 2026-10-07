# Clean port

The Clean workflow is incomplete. There is no native Clean dialog or Finder Clean
route yet, and no cleanup execution API is exposed by this first reader step.

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

## Remaining work

- Native resource-matching controls and per-repository option persistence.
- Finder/main-app command routing and file-to-directory scope adaptation.
- Initialized submodule traversal with access leases and recursive scope rules.
- Confirmed Trash/permanent execution, stale-plan validation, cancellation and
  partial-result reporting, Retry and dry-run post-actions.
- Displayed light/dark layout, original icons, keyboard/VoiceOver and signed sandbox
  acceptance. The Core checks do not establish native dialog parity.
