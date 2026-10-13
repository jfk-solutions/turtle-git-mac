# Add selector drops and owned lifetime

Pinned source: `7338078f8ddd924b8cddee35f512f2286072136d`,
`AddDlg.cpp::OnFileDropped` and the shared status-list drop/check behavior.

Add enables file drops on its changes list. It checks each item's repository,
expands the scope if the item is not already shown or covered by an existing
folder, resets remembered checks and refreshes after the batch. Unlike Commit's
handler, Add does not run `git add` when an item is dropped. OK returns the checked
list for the existing separately owned Add progress workflow.

The Add AppKit table now registers for file URLs, advertises Copy and accepts
through its own native dragging callbacks. The destination is the table rather
than the entire dialog. Its own drag, non-file URLs, busy/confirmation/sheet state
and retired owner are rejected. No file promise or content copy is used.

Add and Commit share the read-only Core repository-membership resolver. It
preserves provider order, removes exact duplicate paths, rejects foreign/nested
roots and metadata, resolves parent aliases and retains leaf symlink semantics.
Commit then runs its ordinary per-item adds; Add only reads and refreshes its
selector. The shared membership query leaves index bytes unchanged. Status
queries retain Git's existing refresh semantics; dropping in Add does not stage
new blobs, move files or modify working bytes.

New file/folder scopes are appended only when necessary. Root drops switch to
whole-project scope. Unrelated existing checkbox choices remain. Dropped rows and
folder descendants return to the source's automatic/direct-file checks. An
ignored row already shown in whole-project scope returns to its unchecked default;
a directly requested ignored file retains the source's direct-file check. This
corrects the earlier blanket check-all behavior for dropped ignored rows.

The selector now owns cancellable read/drop tasks and publishes a snapshot only
after its status, HEAD and flag reads all settle. Cancel waits for the owned work,
then closes. Forced closure invalidates the model, cancels its read token/task,
closes owned sheets/Ignore and rejects late reads, drops and confirmation replies.
Retired file commands and Apply cannot launch another action. Add-model-owned
operations are globally counted until their tasks finish, even after the window
closes. External Revert/Ignore progress retains its existing owning workflow.
Already accepted filesystem/index actions can settle; this is not a rollback
promise. Broader permission-panel and external-workflow acceptance remain open.

The complete existing Add receiver has moved unchanged in behavior to the common
app-object compilation cache and now runs against both system and bundled Git.
Its assertions still cover menus, clipboard, flags, comparisons, ignored/check
rules, Restore, Revert, Save/Export, Delete and progress. Dynamic color assertions
compare resolved RGBA values in Aqua and Dark Aqua rather than provider-object
identity; auxiliary fixture directories are isolated per engine/case.

Physical Finder pointer/drag delivery, every alias/volume, VoiceOver, signed
sandbox grants and complete Add parity remain open. Private pasteboard verification
is not signed Finder acceptance.

The batch passed fourteen Core tests, the Debug build and six unique native
cases across Add/drop/Commit with both Git engines. See the
[scoped evidence and fixture repairs](qa/add-drop-2026-10-13.json).
