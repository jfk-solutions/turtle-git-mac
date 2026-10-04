# Submodule Update parity

The references are pinned to `7338078f8ddd924b8cddee35f512f2286072136d`:
[SubmoduleUpdateDlg.cpp](https://github.com/TortoiseGit/TortoiseGit/blob/7338078f8ddd924b8cddee35f512f2286072136d/src/TortoiseProc/SubmoduleUpdateDlg.cpp)
and `.h`, `IDD_SUBMODULE_UPDATE`, and the Update branch of
[SubmoduleCommand.cpp](https://github.com/TortoiseGit/TortoiseGit/blob/7338078f8ddd924b8cddee35f512f2286072136d/src/TortoiseProc/Commands/SubmoduleCommand.cpp).
All three source blobs were verified against the file inventory. The
[official Submodules manual](https://tortoisegit.org/docs/tortoisegit/tgit-dug-submodules.html)
was also reviewed. This work does not port Submodule Add or Sync.

## Native options and selection

The window follows the resource arrangement: selected paths above two columns of
options, followed by Select/deselect all, Whole Project and OK/Cancel/Help.
Initialize submodules starts enabled; Recursive, Force, No fetch, Merge, Rebase
and Remote tracking branch start disabled. All seven options are retained per
repository after acceptance. The selection is a native multiple-selection list,
not per-file checkboxes. The native three-state all control clears a mixed
selection, and selects all from the empty state. OK is disabled without selected
paths. Whole Project expands a scoped folder request; an unscoped request disables
that redundant toggle. F5 refresh preserves the current selection.

Window frame and repository scope/selection/options are saved using native
preferences. Path selections use a string array, preserving literal pipes and
newlines rather than using a separator-delimited registry string. Original
Update artwork is used by the app and Finder action. Selecting an initialized
indexed submodule root routes Update to its superproject; files within it retain
their containing repository.

## Git execution

Available paths combine index gitlinks and `.gitmodules` entries, with exact
component-based scope matching and natural sorting. Config names and values are
queried separately using NUL delimiters, without following config includes.
Selections are revalidated before Git runs. Missing/duplicate selections,
escaping configured paths and checkout symlinks/non-directory objects are
rejected before checkout. `.gitmodules` must be a regular file.

Flags follow the upstream order, including both independently chosen Merge and
Rebase flags. Git receives the reviewed paths explicitly after `--`; selecting
all within a folder cannot inadvertently update another folder's modules. Git
controls initialization, checkout, Force, fetching, remote tracking, merging,
rebasing and recursion. Updates preserve the superproject HEAD and staged
entries; remote tracking can leave the checkout ahead of its indexed gitlink.
App Store mutations require the repository's active security-scope lease.

The current native implementation reports command output in the options window
and supports another attempt after an error. Busy controls, close and application
Quit are blocked during Git execution. Idle Update controls are also disabled
while another window's Quit confirmation is pending. This is partial progress
parity: the upstream separate command-progress window, live output,
cancellation and bisect post-actions remain to be ported.

## Verification

Six real-Git tests cover scoped literal Unicode/comma/newline paths, Init enabled
and disabled, selected initialization with another checkout retained, Force and
dirty-checkout rejection, Remote/No fetch branch behavior, distinct Merge/Rebase
histories, recursive nested initialization, unchanged superproject HEAD/index,
invalid/stale selections and escaping config. A disposable executable wrapper
allows only the local file protocol for these test fixtures without changing
user Git configuration. The focused Update/selection/icon suite passed all ten
tests. The full Swift suite passed 232 tests with zero failures. The existing unique-icon assertion was updated to recognize that Update
and Fetch share the original Update artwork.

Native QA checked Whole Project expansion, native keyboard selection, mixed/all/
none state and disabled OK, returning to scoped selection, Cancel without
mutation, selective Init/No fetch execution, saved options on reopen and F5.
Only the selected module became initialized; its checkout matched the base;
the other module, parent HEAD and indexed entries remained unchanged. The real
captures are `site/assets/submodule-update.png`, `submodule-update-result.png`
and `submodule-update-dark.png`. They were visually inspected and copied
unchanged. The dark capture was repeated after refresh finished so that it
shows idle enabled controls. Each sequential scenario closed its test process
and verified absence before another instance opened; no instances remained.
A stale row observation used the same process and native keyboard navigation.
An observation timeout after Cancel was followed by normal Quit, not a restart.

Unsigned Debug and App Store builds passed with the embedded Finder extension,
licenses, all 59 artwork resources and the pinned universal Git runtime audit.
Signed Finder activation, sandbox/network authentication, native Force/Merge/
Rebase/error/busy-Quit variants, resize and multi-display frame restoration,
ordinary-file request scope normalization, full list context commands, Add/Sync
and comparison-window integration remain
pending. Inventory entries remain partial and this is not App Store approval.
