# RefLog notes and patch creation

Pinned `GitLogListBase.cpp` offers Edit Notes for a single non-stash revision and
Create Patch for a non-stash selection of at most two rows, or a continuous larger
selection. `GitLogListAction.cpp` opens the shared Input/Format Patch workflows.
A single patch row supplies its revision; multiple rows supply the oldest selected
revision plus `~1` and the newest selected revision. RefLog's order is event order,
not a new topological sort of those hashes.

RefLog now adds both entries with the original Edit/Patch icons. Patch defaults
are derived from event selectors, retaining two distinct rows that share a hash.
The new preset helper checks continuity by row position and rejects stale/unknown
selectors. RepositoryModel opens the existing Format Patch dialog with that preset;
its review, export/directory grant, progress and Send Patch routes remain shared.

Edit Notes first reads the captured revision's immutable metadata, then delegates
to the same Log note model and `CommitNotePresenter` used by Log/Rebase. It opens
the native Input sheet with saved font, project language/width and minimum-length
settings. Accepted text saves to the captured note snapshot even if the parent
selection changes; Cancel discards the draft. The existing note-write and private
preference/sandbox policies are reused rather than duplicated.

The parent observes the note model and disables conflicting controls while its
read, sheet or write is active. Closing invalidates both models and closes the
owned input presenter. Refresh cancels a pending note read; a late result cannot
open a sheet after the parent closes or refreshes. Shared note read/save counters
remain in global Quit accounting until their operations settle. An already accepted
write retains the shared workflow's noninterruptible save semantics.

Notes and patch creation retain their source availability in bare repositories
and during an active merge. Picker windows and stash rows omit them. The existing
Merge/Rebase/Cherry Pick/Revert family keeps its working-tree/active-merge gates.

Focused Core checks cover repeated-hash event ranges, one/two/continuous/disjoint
selections and the existing Format Patch operations. Native checks dispatch the
production menu targets, verify patch preset capture, actual note sheet/font/
minimum-length behavior, captured-revision Git note writes, Cancel, parent gates
and forced-close late-read cancellation. HEAD/index/working-file bytes remain
unchanged; the intended notes ref changes on accepted Save. The patch callback is
probed without executing export or mail delivery.

Remaining acceptance includes physical bare/stash/picker and refresh-during-read
variants, Format Patch export through the new caller, displayed geometry/keyboard/
VoiceOver, accepted-save closure timing, signed grants and full RefLog/source/app
parity. Bisect and commit-combination actions remain to be ported to RefLog.

Eight focused Core tests, the Debug build and four grouped native receivers
passed with system/bundled Git. All receivers were reaped. [Evidence](qa/reflog-notes-patch-2026-10-13.json)
records these scopes; no complete source or signed distribution certification is
claimed.
