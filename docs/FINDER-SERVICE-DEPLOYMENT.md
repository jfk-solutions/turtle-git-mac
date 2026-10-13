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

The existing App Group name is a development placeholder that must be provisioned
consistently for the app, Finder extension and agent. A developer signing team,
valid profiles and real signed user-approved registration are still required.
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
