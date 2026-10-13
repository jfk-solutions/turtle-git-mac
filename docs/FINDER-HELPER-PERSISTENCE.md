# Helper-owned persistent permissions

The private service permission store completes the receiver's durable grant path.
It stores the watched ID, receiver-created persistent bookmark and relative target
components in a versioned private archive. The transient IPC bookmark is never
saved as the persistent authority or placed in Finder's shared cache.

Installation acquires the full incoming grant set, mints receiver-owned persistent
bookmarks, resolves those bookmarks and validates their roots before replacing
existing registrations. Failure retains the previous disk and in-memory set and
releases temporary leases. The archive is staged with mode 0600 and atomically
renamed after validation; parent directories use mode 0700.

Restoration retains leases for available roots, renews stale/moved scope bookmarks
and keeps unavailable entries with per-ID failures for a future Renew workflow.
Relative targets remain relative to the moved scope. Removal updates only the
receiver's private registry; publication removal remains the cache coordinator's
responsibility. Corrupt/unsupported archives fail instead of being silently reset.

This is receiver infrastructure, not a deployed independent service. Authenticated
IPC, service bundle/startup, signed sandbox permission transfer and App Store
acceptance remain open. The existing actual-process unsigned grant fixture is
expanded to check receiver-owned persistence/restoration; its scope requirement
remains explicitly disabled and cannot prove signed access.

Results are recorded in qa/finder-helper-persistence-2026-10-13.json.

The Debug build and six focused Core checks passed. The two-engine native
receiver passed, then only that case repeated after strengthening restored-access
reads. All parent/child receivers were waited/reaped; parent PIDs independently
verified absent. No full Core, App Store or runtime audit was repeated.
