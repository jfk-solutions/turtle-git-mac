# Commit file and folder drops

Pinned source: `7338078f8ddd924b8cddee35f512f2286072136d`,
`CommitDlg.cpp::OnFileDropped`, `GitStatusListCtrl.cpp::ResetChecked` and
`CGitStatusListCtrlDropTarget::OnDrop/DragOver`.

The source enables ordinary file drops in Commit. Each item must belong to the
same repository, receives `git add -- path` without force, extends a scoped list
when necessary and clears that path's remembered checkbox decision. Directory
checks reset descendants. A 200 ms timer batches the status refresh. The active
ordinary file workflow is separate from the disabled changelist-movement code.
Group headings and the list's own drag are rejected by the source.

The native changes table now accepts Finder file URLs through SwiftUI's native
drop destination, without replacing its AppKit table/selection/menu behavior.
Only file-URL data representations are read; no file promise, content-copy or
plain-text drop is accepted. Providers retain order and URL loads have a bounded
request, cancellation and once-only completion. The table probe converts drop
coordinates to real rows and rejects group headings. Busy, message-only, Quit
confirmation and sheet states reject drops. File URLs from another repository,
nested repositories, metadata and escaping parent links are ignored. Parent
aliases are resolved for repository membership; a leaf symlink is added as a
link rather than reading its target. Root drops stage `.`.

Accepted paths use literal Git pathspecs and individual ordinary adds. Ignored
files are not forced into the index, and a failed item does not stop the remaining
items. The native form reports those failures instead of silently discarding the
source add exit status. No disk item is copied, moved or deleted. Existing staged
content for unrelated paths is retained. Git's ordinary folder/root add semantics,
including embedded-repository handling, still apply.

One refresh follows the accepted batch, preserving unrelated checkbox choices,
message and highlighted selection. A scoped dialog adds paths not already visible
or covered by its scopes; a root drop switches to the whole project. Dropped paths
and directory descendants return to the source's automatic/direct-file check
rules, respecting missing/submodule defaults and ignore-on-commit membership.
Staging mode uses the same add and refresh workflow.

URL reads and Git operations share the dialog's existing owned cancellation
lifetime. Cancel waits for that work before settling; forced closure cancels and
fences late provider or backend replies. A global count continues to guard Quit
until the owned request finishes, even after its window closes. The captured
repository/executable/access lease is retained. App Store mode requires the
captured repository grant before resolving URLs or invoking Git; signed execution
and physical Finder permission delivery remain unverified.

Full mouse-driven Finder drag acceptance, VoiceOver feedback, every alias/volume
case, multi-display coordinates and signed App Store acceptance remain open. This
adds an active Commit workflow; it does not certify complete Commit or application
parity.

The file-drop batch passed eight Core tests and four grouped native cases across
system and bundled Git. See the [scoped evidence](qa/commit-drop-2026-10-13.json).
