# Finder cache agent deployment

The application embeds a separate `TurtleGitCache.app` in
`Contents/Library/LaunchServices` and its launch agent plist in
`Contents/Library/LaunchAgents`. The plist's relative `BundleProgram` points into
the embedded helper. The helper links the containing app's Core/SMTP frameworks
and selects the containing app's Git engine, including mandatory packaged Git for
App Store builds. Its own private container holds receiver-created scope bookmarks;
the shared group contains status, not authority.

Watched Repositories offers **Refresh after TurtleGit quits**, **Synchronize** and
**Login Items**. Enabling uses `SMAppService.agent`; system approval is represented
in the page. It is not registered just by building or opening the page. Only a
valid Apple signing team can enable it. Disabling unregisters it; existing cached
status and private saved grants remain available for a later enable.

Both NSXPC peers set signing requirements before resume, pinning the other bundle
identifier and the current signing team under `anchor apple generic`. Unsigned or
ad-hoc builds fail closed. The receiver bounds authorization message size, validates
its version/schema and installs the grant set through the transactional private
permission store. Requests are private Mach/XPC messages rather than shared files.
The client has a ten-second timeout, one-shot reply completion and explicit connection
invalidation. It retains source leases until handoff settles, including during Quit.

Watch-list revisions trigger synchronization once collection/permission setup is
idle. Ordinary status refreshes do not repeatedly rewrite receiver permissions.
Unavailable local grants prevent replacement of the service's complete set and
report an error, rather than silently dropping still-saved registrations. Explicit
Synchronize retries. The app's existing foreground watchers remain available.

Source references:
- [Apple's SMAppService setup](https://developer.apple.com/forums/thread/802443)
- [Cross-process bookmark guidance](https://developer.apple.com/forums/thread/785735)
- [NSXPCConnection signing requirement](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:))

The initial development placeholder has been replaced by the macOS team-qualified
App Group shared by all three peers. See [signed Finder development](SIGNED-FINDER-DEVELOPMENT.md)
for its signing and namespace rules. Distribution signing and the corresponding
profile/export requirements remain separate release gates.
App Store approval, macOS 13 signed acceptance, denied-peer XPC acceptance, additional
shared-administration permissions, persisted cleanup retries and physical Finder
activation remain unproven. The automated unsigned checks inspect packaging and
fail-closed startup; they never install a background item in the developer's login
session.

The October 13 implementation batch passed Debug and AppStore builds, nine focused
Core tests, four grouped native cases with system/packaged Git, both actual service
packaging/unsigned-startup audits and both bundle audits (AppStore with required
Git). Every owned native parent receiver was independently checked absent. The
website build passed. Initial compilation/project-location/fixture issues were
corrected and only affected checks repeated. Results and limits are recorded in
`qa/finder-service-deployment-2026-10-13.json`.

Additional administration scopes are managed per watched repository under Icon
Overlays → Watched Repositories. Private IPC protocol 2 and receiver archive 2
carry these scopes; existing protocol/archive 1 remains readable. Each receiver
creates its own persistent bookmarks for every transferred folder before committing
the set. Keep app and cache helper from the same build: older helpers reject the
new protocol instead of dropping additional grants. A linked worktree can grant
its main repository's `.git` folder without granting its entire parent directory.

## Background status and recovery — October 15, 2026

Watched Repositories now separates its app-owned Status from the helper-owned
Background column. The helper's authenticated status reply reports each registered
root's active refresh, last successful publication and current collection failure,
plus failures cleaning up removed cache roots. Reports contain identifiers, dates
and diagnostics, without bookmarks or transferable access. A successful permission
handoff no longer presents itself as proof that background collection succeeded.

Check Status reads this report. Retry Background Refresh invokes the existing
helper refresh/cleanup retry without registering a login item or replacing the
permission set. Synchronize retains its separate grant-handoff role. The visible
service controls refresh diagnostics every three seconds while their SwiftUI task
is active; concurrent requests are refused, and pending watch-list synchronization
is drained after a status request settles. The controls show the check time,
connection errors, cleanup failures and an explicit older-helper status.

Status replies are bounded and versioned. A legacy UUID-to-failure dictionary is
readable but cannot certify detailed healthy state. Unknown schemas, duplicate
root identities, malformed legacy identifiers and oversized replies fail rather
than leaving stale green rows. Watch-list revision and service lifetime fences
refuse late publication after registration changes or app-watch retirement.
Disabling clears the report; closing the app retains outstanding handoff leases
until the request settles. Source permissions are not rewritten by status/retry.

[Health/recovery QA](qa/finder-service-health-2026-10-15.json) records the actual
Core/native scopes and repairs. Signed XPC peer acceptance, user-approved agent
registration, physical Finder badges and App Store sandbox/distribution remain
open; injected transport does not establish those gates.


## Signed installed acceptance — October 17, 2026

A universal AppStore-configuration Apple Development build was installed as a
fresh app and granted only a disposable repository through native folder pickers.
The actual app registered its embedded agent with SMAppService, transferred the
watch permission through authenticated XPC, and received successful status reports.
With the main app fully quit, the helper alone published a clean-file edit and
restoration; Finder's badge changed to modified and back to normal. The helper
was then unregistered through the native app control.

SMAppService initially returned `notFound` even though its embedded files were
present and registration subsequently succeeded. The settings status now checks
those packaged files before calling the service missing. Read-only status changes
also replace the selectable text's accessibility identity so it cannot retain its
initial message. The [installed record](qa/finder-installed-2026-10-17.json) retains
actual registration, publication and cleanup scope. Earlier unproven statements
above describe prior checkpoints. Denied XPC peers, extra administration scopes,
minimum supported macOS and distribution approval remain separate gates.
