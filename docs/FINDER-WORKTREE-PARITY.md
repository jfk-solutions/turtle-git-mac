# Finder to New Worktree and post-create continuation

Pinned source: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
`TortoiseShell/ContextMenu.cpp` exposes DropNewWorktree for exactly one working-tree
root or bare repository dropped outside a versioned folder.
`Commands/WorktreeCommand.cpp::DropWorktreeCreateCommand::Execute` appends the
repository basename, strips `.git` and avoids proposing the same source path.
`AppUtils.cpp::CreateWorktree` connects CreateWorktreeDlg, Git progress and the
Submodule Update post-action. The [existing Worktree port](WORKTREE-PARITY.md)
already includes command-line drop presets, options, Git operations and manager
refresh; this batch connects the native Finder source route and continuation.

## Native Finder adaptation

FinderSync does not expose Explorer's right-drag menu. Select one watched
working-tree root or bare repository and choose **TurtleGit → New Worktree…**.
The app asks for a destination parent, then opens the existing creation form with
the source-style proposed directory. This preserves the source/destination
workflow without claiming interception of a Windows drag gesture.

Finder uses its cache and filesystem directory classification only. Nested
folders, files, administrative `.git` paths, unknown repositories and multiple
selections are excluded. The existing Worktrees visibility, placement, extended
menu and icon preferences also govern New Worktree. Container and toolbar menus
do not reinterpret their current folder as a dragged source. No clipboard data
participates in this request.

The app treats a menu request as a hint, not permission. It captures the source,
preferences and initiating window, acquires source and metadata access, and
rechecks that the selected path is an actual repository root. It chooses and
authorizes an existing destination parent outside a working tree. A nonempty
unversioned parent is valid: the proposed checkout is its child. Administrative
paths and their resolved symlink aliases are refused. Corrupt metadata,
ownership, permission and Git-engine errors are not treated as ordinary
non-repository destinations.

After the native chooser detaches, the app rechecks the source and opens New
Worktree. It retains the user's current workspace repository. Opening the form
does not create a directory, branch or registration; OK still captures the
existing Checkout, Force, Detach, new-branch and revision choices before Git runs.
Competing active requests cannot replace an existing draft or duplicate the
chooser. Cancellation, owner closure, retirement and deferred Quit fence late
replies. The preparation and its scopes remain counted through actual worker
and sheet release.

## Completed progress and Submodule Update

Creation keeps its completed percentage at 100 and appends the shared source
status/elapsed/finished footer on success, failure or cancellation after Git
starts. Returning to options retains the prior action log; a new attempt resets
the live progress fields at its actual start. Failed creation cannot launch a
post-action. Cancellation questions and destination panels inherit the owning
appearance and remain owned until their actual sheet callbacks drain.

Submodule Update is a one-shot continuation. It captures the created checkout,
preferences and combined destination/source metadata scopes, then closes the
creation frame. The continuation waits for native sheet and picker detachment,
workers and the frame's onClosed callback before opening Update. The old creation
model is retired at that point; its prior active state is not used to reject a
successfully captured continuation. Deferred Quit, retirement and duplicate/late
replies suppress launch. Actual pending work remains a Quit fence through drain.

The same path applies to manager-owned Add and the top-level creation window.
The child inherits the source appearance and explicit invisible test-window
policy. A linked checkout's primary destination grant retains source metadata
access after the progress frame closes. Normal automatic close still considers
available post-actions according to its saved preference.

## Validation and remaining work

[Dated evidence](qa/worktree-finder-handoff-2026-10-19.json) records the passing
30-method Core group, Debug app build and eight native case/engine pairs with
system and bundled Git. Actual compile failures and fixture failures remain in
the evidence. Every owned receiver was reaped and its absence checked afterward.

The native group uses the real Finder menu payload, private repositories and
preferences, actual hidden folder sheets, the production default OK keyboard
action and the real Update child. It verifies cancel/late/duplicate/deferred Quit,
bare sources, existing nonempty destination rejection, completed success/error
footers, actual owner closure and source/destination grant retention. The retained
group covers Worktree manager operations, progress/cancellation, command-line drop
presets, existing drafts and destination-grant behavior with their original
assertions. Scope providers simulate permission policy; they are not signed
sandbox evidence. Current SwiftUI buttons need not have backing NSButton objects;
the fixture dispatches the actual Return-key default action.

Physical Finder delivery, installed signed extension grants, all native input and
VoiceOver paths, complete original dialog layout and current full hosted/App Store
acceptance remain separate requirements. No whole-port completion is inferred.
