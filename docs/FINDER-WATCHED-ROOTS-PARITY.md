# Persistent watched repositories

Finder Sync requires explicit directory registration. This macOS addition places
Watched Repositories under Icon Overlays, complementing TGitCache's watcher/crawler
workflow. It is not a copied Windows dialog or the independent service itself.

The app-private watched-repositories.json uses security-scoped bookmarks, separate
from the recent-repository list. Startup restores each saved grant without a picker.
Unavailable grants retain their rows and offer Renew Access. Add validates Git root
and permission containment before saving. Replacement keeps the entry ID and rejects
an already-watched target. Moved/stale bookmarks are saved after old-cache cleanup,
so a failed cleanup does not discard the previous path needed for retry.

Each restored root owns its access lease, Git actor, FSEvents stream, coalescing
scheduler and cancellation token. It collects and publishes through the shared
ticket store while the app runs, even when no workspace repository is open.
Superseded publication retries with a fresh collection. Source-style child scans
remain non-writing. Removing a watcher retires its work, invalidates its cached
subtree and then removes its bookmark; other roots remain. An open workspace
refreshes separately. No bookmark enters Finder's shared snapshot.

The native page supplies Add, Remove confirmation, Refresh and Renew Access,
repository/path/status columns, original command artwork and semantic operational
status colors. Changes take effect immediately, like explicit management actions;
the Settings Cancel button does not undo them. Ordinary Settings dismissal is
blocked during management mutations. Closing the page leaves app-owned watches
running. Quit retires streams, cancels reads and waits before its termination reply.

This batch does not add a login/cache process. Signed grants for linked-worktree
administration outside a selected root, multi-grant management, physical Finder
activation, volume relocation acceptance and App Store distribution remain open.
Private/simulated permission checks do not prove signed sandbox behavior.
Validation is recorded after execution in qa/finder-watched-roots-2026-10-13.json.

The Debug build and 15 focused Core checks passed. Four grouped native watch/
publication cases passed on both engines, followed by affected watch/capture
checks after a duplicate-message correction. Both final captures were individually
reviewed; the initial clipped host images were not published. All receivers were
reaped and independently checked absent. App Store rebuild/signing remains
deferred to service packaging; no target or entitlement changed in this batch.
