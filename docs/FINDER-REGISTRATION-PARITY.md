# Finder first-use registration and automatic Clone watches

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
Clone/Create/Switch retain their pinned Git workflows. **Add to TurtleGit…** is a
macOS permission/watch adaptation, separate from Git Add and without a fabricated
upstream menu-mask bit.

## Discovery and permission

Finder registers a command-discovery namespace so a selected, previously unknown
folder can offer Clone, Create repository and Add to TurtleGit. Clone/Create keep
their menu visibility preferences. The application utilities and icon preference
remain independent. Existing known-repository source commands, order and captured
payloads remain in place; Clone is not duplicated.

Discovery registration does not authorize file access. The extension does not run
Git, read folder contents or crawl this namespace. Status IPC, retained directory
observations, filesystem status probes and badge requests are restricted to roots
published by authorized app/cache collectors. Removing a publication clears its
badges. Folder candidates are carried as local file URLs; metadata being denied
cannot prevent the user from requesting permission in the app.

The receiving app owns a folder picker, validates the actual Git root and any
external metadata permissions, then saves the repository in its private recent
and watch archives. Existing workspace contents stay open. Duplicate registration
retains the existing watch identity and unrelated grants. Cancellation, retirement
and delayed answers are fenced by the request's ownership. URL payloads convey no
security scope or arbitrary Git command. Registration runs without opening a
workspace; an existing workspace retains its repository. The single public
**Open in TurtleGit** Service is an explicit workspace entry point when Finder
Sync is disabled or unavailable. Git commands remain in the Finder submenu.

## Successful Clone

After a successful Clone, registration retains its live destination/parent lease
while creating the durable child-repository bookmark. It does not demand another
folder chooser merely because Git returned a child path. Registration is separate
from subsequent workspace adoption and waits for an in-flight watch mutation
rather than silently dropping the result. A registration failure remains visible
alongside the successful clone result; it does not repeat or roll back Git Clone.

Registering a repository does not turn on the independent background service.
The existing **Refresh after TurtleGit quits** opt-in still controls that service;
when already enabled, newly saved watches synchronize through authenticated IPC.

## Verification and remaining acceptance

The [grouped checkpoint](qa/context-registration-2026-10-25.json) records 63
distinct focused Core methods cumulatively passing, the final Debug build, actual
Finder-builder and Services-provider checks, and six registration/Clone/ownership
case/engine pairs passing with system and bundled Git. Prior compile failures,
malformed plist nesting, stale Services UTI classification and canonical-path
fixture failures remain recorded. The final registration log records all six
receivers reaped; the Services check retains sandbox-extension diagnostics.

The private cases cover unchanged workspace, both independent persistence stores,
linked metadata grants, duplicate/watch identities, accepted Clone registration,
failure warnings and cancellation/retirement. They do not establish actual signed
folder grants or installed extension activation. Expanded signed Finder menus,
physical permission prompts, automatic Clone registration and background-service
behavior remain pending for this candidate. Badge size/placement remains owned
by macOS; complete source/VoiceOver and App Store distribution acceptance remain
open.

### Installed acceptance — 2026-10-25

The [batch receipt](qa/context-registration-2026-10-25.json) records a signed
universal development build installed with a recoverable prior bundle. A real
Finder folder outside published roots showed Clone/Create/Add with icons. A local
Clone used actual destination-parent and source permission pickers and saved both
recent and watch records automatically, without a second registration picker.
The installed Log context menu displayed its assigned command artwork.

The first installed Add attempt exposed a real modifier mismatch: Finder supplied
`alternateTool: false`, which registration correctly rejects. The repaired
dispatch preserves the original registration request; the focused builder check
passed all four Shift/Control combinations. After the incremental signed repair,
actual Finder Add opened the folder picker and persisted the selected repository
in both archives while leaving the workspace unselected. Temporary recent/watch
entries and Clone preferences were removed, original record IDs retained, and
owned app/Finder windows closed. Background refresh stayed disabled. This covers
one private local-folder workflow, not every Finder provider or upstream dialog.
