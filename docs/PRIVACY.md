# Privacy in TurtleGit for Mac

This document describes the current development implementation. Recheck it when
adding a bundled engine, credentials, telemetry, crash reporting or online services.

TurtleGit itself has no analytics, advertising SDK or telemetry service. It reads
repositories selected by the user and invokes Git for requested operations. Clone,
fetch, pull and push contact the configured Git remote. Git, SSH, credential helpers,
hooks and filters can have their own network behavior, controlled by repository
and user configuration. The current app does not collect or upload these files to
a TurtleGit service.

Gravatar author pictures are optional and disabled by default. Enabling them in
Log sends a SHA-256 digest (or optional MD5 digest) of a selected commit author's
trimmed, lowercased email to the configured avatar provider. The default provider
is Gravatar; a custom URL can use another provider. The generated request does not
include the plain email address, but its hash can still identify an author. The
provider receives the normal network request information, including the source
IP address. Hiding the feature or closing Log cancels its current request.
Downloaded pictures in a local temporary subdirectory are reused for up to seven
days. Expired files can remain until replaced or removed by temporary-file cleanup;
URLSession can also use its normal HTTP cache. No avatar data is sent to a
TurtleGit service. See [the author-picture guide](GRAVATAR.md).

Saved repository bookmarks, display names and last-known paths live in the app's
private Application Support directory. The bookmark file uses owner-only file
permissions. Sandboxed builds place that directory inside their application
container. The app keeps a security scope active only during an open session.
Closing the session releases a scope it acquired. Forgetting a recent entry removes
its saved bookmark; it does not delete the Git repository.

The app and Finder extension share a local cache of monitored repository roots,
absolute file paths, file statuses and an update time. This cache enables badges.
It does not contain file contents, access bookmarks or credentials. The current
cache can retain status for previously opened repositories and is only refreshed
for the active one; cache management and expiry still need implementation.

Operation output is displayed in the app. Git's stdout/stderr are temporarily
stored in per-command random directories and removed after completion. A forced
termination can leave temporary files for the operating system to clean up.
The development-only screenshot command writes a PNG to the location chosen by
the user and captures only the current application's content view. No screenshots
are uploaded automatically.

No claim of App Store privacy compliance is made yet. Final privacy labels and the
published privacy URL must reflect the tested release build and all its components.
