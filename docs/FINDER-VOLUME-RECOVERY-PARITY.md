# Finder recovery after a repository volume reconnects

This is a connected-workflow continuation against pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`. The source cache's
`src/TGitCache/DirectoryWatcher.cpp` owns watch addition/removal, completion-port
recovery and crawler wakeups in `AddPath`, `RemovePathAndChildren` and
`WorkerThread`. TurtleGit adapts that ownership to macOS volume notifications,
FSEvents, existing sandbox bookmarks and cancellable asynchronous work. It does
not copy Windows completion-port or device semantics into Finder.

## Saved grants, returned paths and healthy watches

Previously a saved root that could not restore its bookmark at startup needed
manual Refresh or a helper restart. Filesystem refresh targeted only sessions
that already existed. A failed existing session could also retain an obsolete
path when a volume returned at a different location.

The main application and independent cache helper now observe volume mount,
unmount and rename notifications. They retry only existing saved grants that
lack a usable session or have a failed collection, including unavailable child
repositories. Healthy sessions keep their watches and publication ownership.
Deferred dialog routers recover only repositories they explicitly accepted;
a volume event cannot make About or a Git dialog crawl every saved repository.
No directory scan, permission chooser, new grant or login-item registration is
part of automatic recovery.

A notification starts an immediate attempt followed, while failures remain, by
bounded delays of 1, 3, 10 and 30 seconds. Concurrent events coalesce into one
pending cycle. Exhausting that sequence leaves the failure visible and waits for
another volume event or explicit Retry. A failed retry does not continually
restart its own sequence. The watcher/collector's first failure can wake recovery
when an already attached root disappears.

## Authority and publication lifetime

Bookmark resolution runs on a worker using immutable captured grant bytes and a
serialized provider where required. The mutable permission archive stays with its
owner. Adoption checks that the same grant still exists. The main application
also reloads the exact archive record before adopting, so an independent owner's
Remove or Renew cannot be overwritten by a late result. Incoming helper grant
replacement retains its separate authenticated handoff and generation fence.

For a failed live session, the resolved replacement authority is retained while
only that session's old collector and stream retire and drain. Healthy peers are
not restarted. A moved root uses the existing old-path contribution removal and
registered-catalog update before publishing its new path. Bookmark resolution
alone is not proof that repository collection or publication succeeded.

The helper's production startup uses the same background authority pipeline.
Its authenticated report marks grants being resolved as refreshing. An explicit
background Retry awaits authority settlement before replying; ordinary status
collection retains its asynchronous publication and error reporting. Finder
queries still cannot authorize an arbitrary path.

Shutdown removes volume observers, cancels retry delays and authority work, and
waits for accepted workers and collectors before releasing their leases and
publication session. Late events and results cannot attach a replacement after
retirement. A provider that cannot immediately cancel remains owned until its
actual return; cancellation is not reported as instant release.

## Evidence and remaining acceptance

The [grouped checkpoint](qa/finder-volume-recovery-2026-10-29.json) records
43 focused Core methods with zero failures, the successful native build and both
system/bundled Git receiver passes. Native checks cover actual private directory
return and moved-path cache/catalog retirement, healthy-peer preservation,
same-owner and independent archive-owner grant changes, bounded event scheduling,
unchanged repository contents and actual lease/worker drain. Both receivers were
independently confirmed absent after reaping. No validation attempt failed in
this batch; pre-validation review repairs are recorded separately.

Local private-root
and injected-notification checks do not establish physical disk/network remounts,
signed sandbox bookmark restoration, authenticated installed XPC, minimum macOS,
Intel execution or every Finder command. Installed build31 predates this family.
A returned resource whose permission is no longer valid still needs explicit
Renew Access; recovery does not manufacture authority from a path.
