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

The original batch did not add a login/cache process or additional grants; later
service and multi-grant work is described below. Physical Finder activation, volume
relocation acceptance and App Store distribution remain open.
Private/simulated permission checks do not prove signed sandbox behavior.
Validation is recorded after execution in qa/finder-watched-roots-2026-10-13.json.

The Debug build and 15 focused Core checks passed. Four grouped native watch/
publication cases passed on both engines, followed by affected watch/capture
checks after a duplicate-message correction. Both final captures were individually
reviewed; the initial clipped host images were not published. All receivers were
reaped and independently checked absent. App Store rebuild/signing remains
deferred to service packaging; no target or entitlement changed in this batch.

## Additional administration permissions (October 15)

Watched Repositories now includes an Additional folder access list for the selected
repository, with Add Folder Access, Renew Folder Access and confirmed Remove Access.
Folder pickers show hidden folders so the main repository's `.git` directory can
be selected for a linked worktree. Renewal preserves the grant identity; removing
an additional grant leaves the watched repository and files in place. Existing
single-folder records decode without migration or another permission prompt.

Each watcher retains all its private security scopes. Changing a grant retires the
old monitor, cancels its reader and waits for that reader before installing the
new session. Root renewal preserves additional grants. The collector validates
root administration directories against the complete grant set before starting
status collection or installing its monitor; child administration is checked too.
The worktree and submodule path boundary remains the selected repository scope.

Private IPC uses protocol version 2 when additional scopes are present. The receiver
resolves every transferred scope, mints its own durable bookmarks, and resolves all
of them before atomically replacing its previous registration. Relaunch renews
moved/stale administration grants while scopes are live. A failed additional grant
retains the saved entry and reports a permission failure rather than running with
partial authorization. Neither durable nor IPC bookmarks enter the shared cache.

This supersedes the earlier single-grant limitation above. The independent service
is described in FINDER-SERVICE-DEPLOYMENT.md. Signed installed Finder activation,
actual sandbox access across volumes and App Store acceptance still require
separate verification; injected bookmark providers do not prove those behaviors.

Validation: the Debug app build and 23 focused Core checks passed. The grouped
watch/service cases passed on system and bundled Git (four case/engine combinations).
New native assertions exercise a linked worktree denied before the extra grant,
publication after granting its main `.git` folder, service transfer of the grant,
and rejection again after removing it. All four owned receiver processes were
reaped. See qa/finder-additional-permissions-2026-10-15.json for scope and limits.


## Captured watch controls — October 17, 2026

Select one or more rows in Settings → Icon Overlays → Watched Repositories, then use Refresh to
refresh all selected repositories, or Remove to stop their watches and remove
cached subtrees. Remove lists the captured paths and offers Cancel first. It
leaves repository files unchanged. Renew Access remains a single-row action.
Select one row to manage its additional authorized folders.

All choosers and removal questions belong to the Settings owner, rather than the
global key window. Leaving the page or closing Settings dismisses owned sheets;
delayed/duplicate replies cannot operate on a later selection. Accepted watch
mutations continue under the application manager. Removed roots and grants are
pruned from selection, including permission changes without a root-ID change.
Grouped real private registry/cache tests passed with both Git engines, including
batch refresh/publication and removal with HEAD/index preservation. This does not
certify physical Finder activation, Login Items or signed bookmark authorization.
See [scope and evidence](FINDER-OVERLAY-SETTINGS-PARITY.md#owned-finder-controls-and-exact-overlay-drafts--october-17-2026).
