# Private cache-service permission handoff

Apple's [Finder Sync guidance](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html)
places state updating in a separate service. Its
[sandbox file-access guidance](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
distinguishes persistent app-scope bookmarks from bookmarks passed between live
processes. This batch implements that distinction before service packaging.

The watched-root manager exports only settled, available sessions. Each private
request contains a stable watched ID, an interprocess bookmark and relative root
components within the retained grant. No bookmark is written to Finder's shared
snapshot. Receiving code resolves with withoutImplicitStartAccessing, starts its
own lease explicitly, checks scope availability/containment and balances release.
Production acquisition defaults to requiring actual security scope.

The protocol rejects unsupported versions, duplicate IDs, empty/oversized bookmarks,
invalid components and symlink escape. Relative components allow a broader folder
grant and preserve the target when a bookmarked scope moves. Failed batch
acquisition releases already-created leases instead of leaving partial access.

A receiver can create its own persistent bookmark from the live granted URL.
Its persistent record retains the watched ID and relative repository path; it does
not save the transient IPC bookmark or replace the target with its parent grant.
The receiver's private registry/transport/startup remain part of the next service
packaging work.

Core checks use injectable providers for scope ownership, moved grants, receiver
persistence and rejected requests. Native checks exercise watcher export and an
actual Foundation bookmark resolved/read by a separate owned receiver. The latter
uses unsigned private temporary repositories and explicitly disables the scope
requirement; it proves codec/process/read behavior, not signed permission transfer.

Authenticated IPC, the embedded login/launch service, helper-owned persistent
registry, signed sandbox grants, App Store acceptance and physical Finder remain
unimplemented/unverified. No login item is registered by these checks. Validation
is recorded in qa/finder-service-grants-2026-10-13.json after execution.

The Debug build, 13 focused Core checks and four grouped native cases passed.
The service group alone was repeated after adding a failed-second-grant assertion.
All owned receiver processes were reaped and independently verified absent.
App Store rebuild/signing remains deferred to service packaging.
