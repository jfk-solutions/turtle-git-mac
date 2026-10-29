# Finder cache persistence and publisher lifetime

In **Settings → Advanced**, `CacheSave` controls restoring and saving Finder's
warm status cache. Its source default is **true**. Enter **false** and Apply to
start subsequent publisher sessions without saved status. Clearing the value and
applying restores the default. This preference does not disable live badges,
context menus, active repository scans or watched-repository permissions.

Finder still needs a live shared status publication while the app or background
helper runs. `CacheSave=false` therefore does not prohibit every shared-file write.
The optional archive used across publisher restarts is separate from this live
communication. No Git repository, index, private bookmark or watched-root list is
erased when the preference changes.

## Live and saved status

A live publisher holds a private advisory lease for its process session. Snapshot
contributions retain the session and exact repository root that produced them.
Readers accept contributions only while the corresponding lease is held. The
operating system releases leases when a process exits, including a crash; PID reuse
and timestamp guesses cannot keep an old publication authoritative. Git/helper
children do not inherit those lease descriptors across execution.

The foreground workspace, watched-root manager and independent helper have their
own sessions. Closing or switching a workspace can retain its cached status while
the application process remains active. Quitting cancels and drains its owned
readers before ending the session. Removing a watched root removes only that
publisher's contribution. Another active publisher's status remains eligible,
including an older contribution exposed when a newer publisher stops.

Finder revalidates live status for badge and context-menu requests. A retained
reader reuses its projected data when the control file and publisher leases are
unchanged. It does not wait for a writer's exclusive lock on Finder's main thread.
An unreadable or invalid publication clears its current state rather than granting
operations from stale cached metadata. Git commands still reacquire permission
and revalidate their targets in the main app.

With persistence enabled, a newly claimed, authorized root may receive its saved
warm status before its fresh scan completes. Saved data is not an access grant and
does not register arbitrary historical roots with Finder. With persistence
disabled, a new claim starts cold and the fresh scan supplies current status.
Disabling persistence invalidates the old archive before it could become eligible
again; a failed cleanup cannot resurrect that archive on a later enable.

## Failure and recovery

A failed Settings publication preserves the saved `CacheSave` choice and displays
its error. Apply remains available to retry without editing the value. Closing and
reopening Settings retains that retry. Cancel closes normally, discards unsaved
edits and does not undo an earlier successful settings save. Application startup
also republishes the saved policy. The connected
[Settings publication recovery](SETTINGS-PUBLICATION-RECOVERY-PARITY.md) extends
durable retry to Finder icons and cache-menu presentation, keeping each channel's
failure and newer accepted preferences independent.

A warm-archive failure does not suppress an accepted live status update. The
helper reports persistence failures separately from per-repository scanning and
permission failures. **Check Status** displays them; **Retry Background Refresh**
retries policy/cache work and current scans without replacing private grants.
A malformed regular warm archive is rejected and can be rebuilt from fresh,
completed live status. Unsafe file types and permission failures remain reported;
they are not silently deleted. Corrupt live status/control files retain their
existing fail-closed behavior.

## Source and native adaptation

The source is pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`:

- `src/TGitCache/GITStatusCache.cpp`, blob
  `f63e9e470d22a0aab857b3abb293a6b8391cae0a`: `Create` checks the default-true
  registry value before disk restoration; `SaveCache` checks it before saving.
  Invalid saved cache is discarded instead of crashing on every startup.
- `src/TGitCache/TGITCache.cpp`, blob
  `1d82a8d505d370187b6d0f90ca1354df2a34b22e`: shutdown stops the cache and saves
  eligible state before exiting.

Windows registry storage becomes the existing native preference. The shared
`status.json` is the compatibility projection, `status.json.writers` coordinates
policy, exact-root ordering and contributions, and `status.json.warm` is the
optional archive. Session leases live in `status.json.sessions`. Control format 3
fences older writers; the former control formats migrate once. Older snapshot JSON
remains decodable, while current app/Finder consumers require live session
ownership. Keep the app, extension and helper from the same build.

Publication tickets retain store/session identities and ordering. Retiring a
session or removing its subtree rejects its delayed reads without erasing another
active publisher. Nested removal preserves the original publication precedence of
a surviving parent contribution while advancing its reader revision. Concurrent
helper shutdown requests join the same drain; restart waits for it to finish.
Policy changes, archive invalidation and accepted publications
share the cross-process store lock. Current runtime data remains separate from
private receiver-created bookmark authority.

## Verification boundary

The connected batch covers native Settings, foreground/watched publishers,
independent runtime restart/shutdown, shared readers and failure/retry reporting.
The [batch checkpoint](qa/finder-cache-persistence-2026-10-19.json) records actual
executed checks and repairs. Private unsigned
receivers do not establish installed Finder timing, authenticated XPC, real login
item approval, signed sandbox grants, minimum-OS behavior or App Store approval.
These remain separate from the implementation and its focused local evidence.
