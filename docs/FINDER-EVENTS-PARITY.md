# Filesystem event monitoring

This batch adapts the change-notification part of pinned TGitCache's
`DirectoryWatcher.cpp` and its crawler invalidation. The Windows completion-port
watcher becomes an owned dispatch-based macOS FSEvents stream. It is not the
complete independent TGitCache service port.

## Implemented behavior

The active app workspace now watches the working root, its Git directory and its
common Git directory. The last two differ for linked worktrees; a shared config,
reference or repository-state change can therefore invalidate the active child.
Paths are resolved through Git with absolute-path output, preserving embedded
newlines. Duplicate directories are removed. App Store monitoring filters those
roots through the retained access lease; out-of-grant administration directories
still require signed permission acceptance.

The stream requests per-file events and root changes, with dispatch delivery and
bounded latency. Dropped events, MustScanSubDirs, mount/unmount and root changes
are recognized as full-rescan conditions. All current invalidations perform a
complete foreground repository/snapshot refresh, so those conditions never depend
on an incomplete per-file update. FSEvents can report canonical physical paths;
consumers comparing paths must normalize Cocoa URLs instead of assuming `/var`
and `/private/var` spellings match.

Event bursts coalesce. A busy workspace or Quit confirmation retains a pending
refresh, which resumes when its gate clears. Events during a refresh request one
subsequent refresh. Repository Open/Close replaces and retires the stream and
scheduler; a generation fence rejects callbacks already queued by the old stream.
The stream stops, invalidates and releases its context on retirement/deinit.
Failed Open restores monitoring of the retained previous repository.

The fixed five-second polling timer is removed. Foreground status reads now use
GIT_OPTIONAL_LOCKS=0, avoiding optional index writes that could trigger feedback.
The existing snapshot/submodule aggregation and App Group publication remain;
Finder receives its distributed notification only after a successful write.
Private repository factories, snapshot writers and notification callbacks let
native verification exercise the real model without writing shared cache or user
preferences.

## Evidence and remaining work

Core checks cover actual Unicode/newline file creation and rename events, stopped
streams, invalid roots and dropped/root-change flag classification, linked-worktree
watch discovery, cancellation without HEAD/index changes, burst/busy coalescing
and retirement. Native checks cover actual app-model file edits, snapshot and
notification publication, busy/Quit deferral, non-writing status reads, close
retirement and shared-admin linked-worktree invalidation.

The initial event assertion failed on canonical `/private/var` output; comparing
normalized URLs fixed the fixture while retaining exact file targeting. A second
native fixture timeout compared directory-hinted URLs with different trailing
slashes despite successful linked Open; comparing exact path strings corrected
it. Actual runs, failures and ownership are in
[the verification record](qa/finder-events-2026-10-13.json).

An independent cache/login service, multiple watched-root management, crawler
incremental/scalable invalidation, lock-aware delays and cancellation of in-flight
foreground reads remain open. FSEvents does not grant filesystem permission.
Physical Finder badge/menu refresh, signed grants across linked administration,
volume removal/rename acceptance, root-drop integration and App Store acceptance
remain unverified. No dialog or complete Finder integration is certified.

Debug and unsigned App Store builds passed. Three unchanged Core checks plus the
corrected actual-event check passed; only the affected event check was repeated.
Two native model cases passed with system and packaged Git. Both failed and
passing receivers were reaped and independently verified absent. The website
build passed. No full runtime audit, Finder activation or signed deployment was
repeated/established by these focused results.

The later [collector batch](FINDER-COLLECTOR-PARITY.md) adds cancellation across
the complete metadata/recursive read chain and removes optional child-index writes.
It establishes watches before the first status read through a watch-ready handoff.
The independent service and signed/physical acceptance remain open.
