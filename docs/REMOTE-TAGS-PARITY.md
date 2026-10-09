# Delete remote tag parity

Reference: pinned upstream `DeleteRemoteTagDlg.cpp/.h`, `IDD_DELETEREMOTETAG`,
`CGit::GetRemoteRefs`, `CGit::DeleteRemoteRefs`, and BrowseRefs folder dispatch.
This is a native partial port; physical and signed acceptance remain unfinished.

The native dialog has a read-only, selectable Remote field, headerless native
multi-selection tag list, Select/deselect all mixed-state checkbox, Delete and
Close. Names omit `refs/tags/`; annotated peeled `^{}` records are excluded.
Natural ordering and `SortTagsReversed` macOS preferences mirror the source's
normal/reversed tag list choice. Foundation natural ordering is not proven equal
to Windows logical ordering for every locale/name.

No selection disables Delete. Partial selection makes the checkbox mixed; manually
cycling to mixed deselects everything, as the source does. Delete captures displayed
selected names before awaiting confirmation. Source single/count question text and
Delete/Abort buttons are retained; Abort is the default. Abort preserves selection
and the catalog. Accepted deletion sends one batch Push with `:refs/tags/<name>`
refspecs. The list refreshes after success or failure, clears selection and stays
open. Local tags, branches, HEAD, index, worktree and config remain intact.

Loading and deletion use owned native progress sheets with source Loading/Deleting
remote refs and Please wait text. Active loading/deletion/confirmation blocks
selection, F5, duplicate deletion, ordinary Close and Quit. Forced dialog/browser
or progress-sheet closure cancels owned Git process groups, releases sheets and
rejects late lists/errors/confirmation results. App Store repository-scope checks
precede backend access. Remote transport scope/authentication and signed behavior
remain unverified.

Tag folders receive Delete remote tags on each configured remote with original
Delete artwork. Remote folders and descendants resolve the configured first-prefix
remote and offer Fetch from that remote plus Delete remote tags. Remote tag closure
does not refresh the reference browser, matching the source. Fetch retains its
existing owned dialog, preset, progress and browser Refresh behavior. Manage Remotes
now opens the native settings page from remote folders; full folder parity remains
incomplete. See REMOTE-SETTINGS-PARITY.md.

Browser metadata's bare-repository read now receives the same cancellation token
as its catalog request, so forced close cannot leave that subprocess unowned.
Full metadata/transport timing coverage remains unfinished.

`test-remote-tags.py` uses private local/bare repositories, hidden shipping native
menus/list/controllers, intercepted progress-sheet presentation and confirmation.
It checks selection, tri-state, Abort/Delete/Refresh, captured remote isolation,
owned progress and close/Quit gates, late Yes and recorded live helper/leader
termination in tag loading, validation and Push. Core tests cover annotated/packed
Unicode tags, normal/reversed ordering, URL input, one batch deletion, rejected
Push, invalid batches and pre-cancellation. See `qa/remote-tags-2026-10-09.json` for
final results and explicit limits. No main app, external network, installed Finder
extension or screenshot is activated by these checks.

Native configured-key loading now precedes tag catalog and accepted batch Push,
with a fresh operation-owned coordinator for the post-deletion refresh. Validation
and confirmation precede destructive transport preparation; no extra checkbox is
added. This is a macOS extension of the remote-tag workflow: pinned source
DeleteRemoteTagDlg itself does not call Pageant. See SSH-TRANSPORT-PARITY.md for
private-agent lifetime, encrypted response, cancellation and runtime limits.
