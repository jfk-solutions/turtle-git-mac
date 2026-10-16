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
