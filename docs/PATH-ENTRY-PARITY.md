# Filesystem completion across path-entry dialogs

Pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d` installs shell
filesystem completion in `CloneDlg.cpp` (IDC_CLONE_DIR), `RenameDlg.cpp` (IDC_NAME),
`CreateWorktreeDlg.cpp` (IDC_WORKTREE_DIR) and `ExportDlg.cpp` (IDC_EXPORTFILE).
The native equivalents now share an AppKit text field and TextKit field editor.
The dialogs keep their source groups, labels, Browse actions, keyboard order and
existing Git validation. This replaces the prior plain fields, without adding
new checkboxes or changing their commit/clone/export/rename behavior.

A short typing delay reads only the entered parent directory on a background
worker. Matching includes both files and directories, with natural native order;
directories add `/`. Spaces, Unicode, literal brackets and newlines remain data.
Relative spellings such as `../` are retained. `~/` choices expand to an absolute
path when selected, so they work with the existing destination consumers. Ordinary
typing is not normalized. Dot-files are offered for an explicit dot prefix.
URLs do not trigger filesystem enumeration; no shell interprets user text.
The native completion range covers the full field instead of treating spaces or
punctuation inside a path as word boundaries. Explicit Complete requests can
query an existing value as well as text entered during this session.

AppKit supplies the completion list and selection/Return/Tab/Escape behavior.
The normal field, Undo and focus loop remain native. Input-method marked text,
disabled/retired controls, an owned sheet and a changed initiating model reject
completion work. A stale result cannot replace typed text or reopen a popup.
Rename retains its initial name focus; other callers retain their existing focus
order. Completion failure leaves the draft editable without a Git error alert.

Every request captures its base directory, immutable text and existing access
leases. Cancellation supersedes old lookups; closure removes the view's callbacks.
The leases survive actual reader settlement. In AppStore mode enumeration requires
an existing permitted parent folder, including related grants. A file-only grant
does not permit sibling enumeration. Symlink-parent containment uses the existing
physical-path policy. No completion read opens a permission prompt or grants new
access; Browse remains the explicit selection route. Read-only in-process directory
lookups create no child process and do not independently block application Quit.

Windows shell history/URL providers and exact locale/hidden-file policies are not
reimplemented. Native filesystem ordering, paths and access controls adapt this
feature to macOS. Full physical completion-popup/keyboard/IME/VoiceOver behavior,
network/large directories, directory-alias races, all themes/geometry and signed
Finder/AppStore access remain acceptance work. No full dialog or port certification
is implied. The Debug build and six grouped native cases passed on the first run,
with system/bundled Git. The new receiver uses actual shipping fields/TextKit
binding while injecting popup presentation; retained Rename and creation-picker
cases perform their existing real Git mutations and ownership checks. All six
receivers were reaped and independently absent. Core was unchanged and not rerun.
[The dated evidence](qa/path-entry-2026-10-16.json) records actual scope, Xcode's
exit-zero/no-output diagnostics, hidden-view layout warnings and open acceptance.

## Literal input and native completion interaction — October 16, 2026

The four path editors now disable prose substitutions, spelling correction and
automatic prose completion for their own field editors. Quotes, repeated dashes
and Unicode remain literal filenames without changing system preferences.
**Complete Path** appears in the native field context menu with upstream artwork
and the owning dialog's app-menu icon preference. Each captured action is usable
once and expires when its text, selection, request generation or owner changes.

Delayed directory replies also compare the initiating caret/selection. Deferred
initial focus leaves an already active editor or another focused control alone.
Only the current key, non-minimized window can present the Cocoa completion list;
background lookup does not bring a dialog forward. Existing scope, sheet,
disabled-control and retired-window guards remain in effect.

The grouped verification exercises shipping views and field editors, preview
cancellation, native Undo/Redo, menu preferences/lifetime and held successful
replies after caret movement. The separate foreground popup experiment did not establish keyboard acceptance:
the current SDK exposes remote text-service windows and the expected in-process
completion table was absent. Its failed fixture is retained as evidence and is
not part of the passing CI group. Physical popup/keyboard, input-method, VoiceOver
and signed Finder/AppStore acceptance remain open. See the dated interaction
[evidence](qa/path-entry-interaction-2026-10-16.json) for results.
The four affected native case/engine pairs passed after repairing a real
completion Undo/model synchronization defect. No Core suite was rerun.

## Account-home paths across native workflows — October 31, 2026

The shared `UserAccountPaths` policy resolves the current UID's home with a
bounded, thread-safe `getpwuid_r` lookup and Foundation fallback. Resolution is
cached once per process, so path menus do not query the account database for each
item. It supplies locations without granting access or changing process `HOME`.
Explicit caller-supplied home/directory values retain their existing precedence.

Report discovery, the report editor's default home-path substitution and its
crash-report chooser now agree on the account home. The chooser uses the model's
captured home, including explicit test/application injection. SSH key generation
suggests the account `.ssh` folder while retaining an already selected folder.

Bare `~`/`~/…` expansion is shared by Merge command entry, lexical two/three-file
and patch selection, native Merge Open, path completions and image loading.
The home prefix changes while filename-tail bytes remain intact. Named-user
lookup retains the platform's existing behavior. Authorization and read targets
use the same expanded path. Existing grant checks still precede completion
listing and selected-file reads. Finder menu and overlay include/exclude patterns
use the same account home for `~`/`$HOME`; explicit home injection, matching
precedence, case handling and invalid-pattern diagnostics remain.

Git configuration/environment semantics, private cache/container storage and
external-document access ownership are separate policies. This batch does not
reinterpret their process `HOME` or authorize new locations.

The [grouped checkpoint](qa/account-home-workflows-2026-10-31.json) passes one
Debug build,35 focused Core methods and native completion, Merge Open and image
Open cohorts. Synthetic account/container homes exercise the policy without
reading user directories; actual native fields retain permissions, editing,
cancellation and retirement behavior. The Paths driver first had an indentation
error; its retry exposed an older Export caption mismatch (`ZIP file` versus
`Archive file`) and weak initial-load admission. Those fixture repairs and all
attempts are retained. Only Paths was repeated; passing build/Core/Merge/image/
documentation checks were not repeated. All owned receivers were reaped and
independently absent.

This source batch is not installed in build45. Real signed-account folder
pickers, network homes, physical Finder and keyboard/accessibility/Intel/minimum
macOS execution and complete hosted integration remain separate.
