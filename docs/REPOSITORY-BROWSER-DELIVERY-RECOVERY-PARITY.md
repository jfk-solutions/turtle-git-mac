# Repository Browser navigation and historical delivery

Partial review of `IDD_REPOSITORY_BROWSER`, `RepositoryBrowser.cpp` Refresh/F5,
list activation and list/tree BeginDrag at pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`. Existing namespace, stored-file and
selection-transfer records remain applicable; this review does not certify every
Browser control or the full port.

## Implemented family, 8 November 2026

F5 now retires a pending historical file read and advances the tree generation
instead of silently refusing Refresh. Folder navigation can likewise retire a
cancellable read, including immediate cached-folder navigation. The original
request, cancellation token and permission lease stay owned until its actual I/O
drains. A fresh listing can become usable while that obsolete worker remains
accounted for. Its late bytes, errors and callbacks cannot publish another
document or clear a newer operation's busy state.

Revision edits compare exact Git reference bytes and cancel pending delivery.
Native file choosers, mutations, Quit and column-reset questions retain their
separate navigation fences. Already dispatched external applications keep their
historical preview according to the existing receiver-lifetime policy; refreshing
the Browser does not reinterpret those bytes as a new revision.

Transfer inventory and lazy-directory reads keep the accepted snapshot backend.
Direct historical providers/promises also prefer that captured configuration
before any global fallback. Drag admission binds the actual mouse hit row/item
to the selected native transfer. A stale/programmatic delegate call cannot
substitute another tree node or list selection. Accepted transfer receipts remain
immutable and may finish after refresh, branch movement or owner closure, using
their original object bytes and safe historical filenames.

Browser retirement retains its presenting parent, attached child, file worker and
revision-picker release until real sheet detachment and I/O completion. Closure
is idempotent, including an invisible controller. Stored inspection windows close
with their owner; independent historical drag promises retain their own lifetime.

The native table fixture now exercises real gesture capture and
`writeRowsWith`/`writeItems`, retaining its original ordered promise delivery and
source-state assertions. Namespace delivery adds named held-read Refresh,
cached-folder navigation, revision-change and attached-parent retirement checks.
The root-tree drag asserts all original top-level promised items; folder drag
asserts its one folder. This follows source recursive tree selection rather than
restoring obsolete private per-item delegate methods solely for a test.

## Validation and explicit remaining boundaries

Implementation and assertions are frozen for the shared History/Browser/Export
checkpoint. No pass is inferred from this source review.

- Raw Git names remain distinct from escaped display labels and native delivery
  names. Unrepresentable individual files use safe temporary names with original
  bytes; literal folder delivery still refuses descendants that cannot be
  represented safely on the destination filesystem. Folder archives are the
  existing separate workflow.
- Submodule navigation and existing comparison/Log handoffs retain their pinned
  revision and accepted backend; this batch does not add new submodule commands.
- Physical drag-and-drop into third-party applications/Finder, external editor
  approval and receiver lifetime, keyboard/IME/VoiceOver, signed grants and every
  light/dark upstream control layout remain separate acceptance work.
- A focused hidden receiver pass does not establish complete hosted CI or an
  installed/signed update. Installed52 and immutable candidate53 are unchanged.

The [grouped recovery checkpoint](qa/history-browser-recovery-2026-11-08.json)
records passing affected Core/native scope, original failures and focused repairs.
It does not certify complete physical, signed or whole-port acceptance.
