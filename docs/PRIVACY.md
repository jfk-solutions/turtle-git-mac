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

The persistent [action log](ACTION-LOG.md) keeps displayed operation output,
local timestamps and repository paths in private Application Support storage.
It may include displayed Git/hook output and remote addresses. Its default
retention is 4000 lines, with the complete newest operation always retained.
Settings → Saved Data lets users show or clear it; setting the line count to 0
disables new entries without deleting old ones. TurtleGit does not upload it.

Saved repository bookmarks, display names and last-known paths live in the app's
private Application Support directory. The bookmark file uses owner-only file
permissions. Sandboxed builds place that directory inside their application
container. The app retains scopes for open workspace sessions and explicitly watched
repositories. Closing a workspace releases its scope; watched repositories retain
their scopes until removed or the app quits. The optional background cache agent
receives grants over authenticated private XPC and creates its own persistent
bookmarks in its private sandbox container. While enabled, it retains scopes to
watch repositories after the main app quits. Disabling the agent stops its watches
but retains its private saved grants for a later enable. These bookmarks are never
placed in Finder's shared cache. Forgetting a recent entry removes
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

Settings → [Saved Data](SAVED-DATA.md) can clear URL/directory histories, input
message histories and remembered answers. These operations remove local
preferences only; they preserve repository bookmarks and working files. The
action log is cleared separately.

Temporary files now use the private `TurtleGitTemporaryFiles` directory under
macOS temporary storage, including Git stdout/stderr, previews and cached author
images. [Saved Data temporary-file cleanup](TEMPORARY-FILES.md) clears that folder
after confirmation. It preserves repository/bookmark/history/action-log storage.
Already displayed author images and HTTP-cache responses can remain; old builds'
temporary files outside the new folder are not scanned or deleted.

Saved native window sizes and positions live in app preferences.
[Saved Data's geometry Clear](DIALOG-GEOMETRY.md) deletes those records and known
legacy frame-autosave entries; it preserves histories, bookmarks and repositories.

Blame keeps up to four recent HEAD files in a separate private `blame-files.json`
archive with folder bookmarks, relative repository/file paths and display paths.
Bookmarks are used only after containment/security-scope validation. Successful
reopening renews moved grants; failed entries remain until replaced by later
recent-file use. The archive is atomically written with owner-only permissions
and is not shared with Finder or uploaded.


At launch, the local problem-report helper checks up to 32 recent candidate Apple
`.ips`/`.crash` files in the current user's DiagnosticReports folder. It requires
both this app's process name and bundle identifier, rejects symlinks and oversized
files, and does not traverse subdirectories. Reports older than 30 days are
ignored. An inaccessible folder is skipped without requesting broader access.
You can disable **Check for crash reports at launch** in Help → Report a Problem.

Discovery and review do not upload reports. A discovered body stays in memory
and is excluded from Copy/Save until Include is selected. Review or Dismiss saves
only its SHA-256 content hash in a bounded history of 64 handled reports; report
bodies and report paths are not saved as preferences. Dismiss does not delete the
Apple report. Manual import and the separately opened blank issue form retain
their explicit sharing workflow.
