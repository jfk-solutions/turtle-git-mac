# TurtleGit selected-file Services

TurtleGit advertises six macOS Services for selected files and folders. They give
users an entry point outside Finder Sync's monitored repositories, through the
system's **Services** menu. They also work with file selections supplied by other
apps that support macOS Services. Availability and ordering are controlled by
macOS; these entries do not extend Finder Sync's ordinary context-menu coverage.

| Service | Captured operation |
| --- | --- |
| TurtleGit: Show log… | Existing Log workflow for the selected Git paths |
| TurtleGit: Commit… | Existing Commit workflow with the selected paths |
| TurtleGit: Check for modifications… | Existing status workflow for the selection |
| TurtleGit: Diff… | Two selected regular files use direct comparison; other selection counts use the existing repository Diff workflow |
| TurtleGit: Clone… | Existing Clone dialog, starting from one selected directory |
| TurtleGit: Create repository… | Existing Create repository dialog for one selected directory |

Clone and Create advertise folder selections only. They require one existing,
ordinary directory; filesystem roots, symlink leaves and Git administrative paths
are refused. Dialog validation and user confirmation still apply. Two-file Diff
validates both files before comparison; selecting two directories does not turn it
into an unsupported directory-comparison operation. Git-dependent commands retain
their existing repository, working-tree and selection restrictions.

Launch the installed TurtleGit app bundle once so macOS can discover its Services.
Select files or a folder in Finder and look under **Services** in the context menu
or Finder menu. If an entry is disabled or hidden, review macOS Keyboard settings
under **Keyboard Shortcuts → Services**. The unbundled SwiftPM executable does not
register the app bundle’s Services declarations.

## Selection and permission

The provider receives the caller's private Services pasteboard. It captures file
URL items in their original order, with a legacy filename-array fallback. It does
not read the general clipboard, execute pasted text, or split paths on whitespace
or newlines. Spaces, Unicode, punctuation and line breaks remain literal path
characters. Duplicate normalized paths are removed while retaining first-seen
order. Empty, non-file, administrative, mixed malformed and oversized selections
are rejected with a Services error. The limits are 10,000 incoming items and a
1 MiB encoded request; this is a transport bound, not a repository-size limit.

A selected URL is not authorization. The app uses its existing repository access
leases or an owned **Allow repository folder access** chooser. All requested items
must be covered before Git discovery or action dispatch. Linked metadata and
additional repository access continue through the existing discovery workflow.
For repository operations, a selected symlink stays a Git path in its containing
repository; discovery does not switch to the repository it points to. Direct
two-file comparison requires permission to read the actual file targets.
Cancelling the chooser stops the request. Its sheet, callbacks and repository
owner remain accounted for until they actually release; closing an owner or
quitting cannot turn a late reply into approval. Existing operations retain their
own cancellation behavior and do not promise rollback after a completed write.

The command and paths remain captured through permission and discovery. They are
not replaced by a later Finder selection or workspace selection. A busy workspace
or Quit confirmation rejects a new service immediately. During cold startup one
typed request can wait for the workspace; a second request is rejected, and a
later dispatch rejection produces a visible workspace error. A running standalone
merge tool forwards the typed request to a separate workspace, retaining the
handoff receipt until Launch Services replies. Its private
`turtlegit://service` envelope selects the owned Services route and conveys no
permission.

## Registration and source scope

`Configuration/App-Info.plist` supplies the six `NSServices` declarations.
`ApplicationDelegate.swift` installs one provider after startup preparation,
restores a previous provider only if TurtleGit still owns the registration, and
retires pending service input during termination. Services do not automatically
stage, commit, clone or initialize anything merely because a menu opens.

The pinned source comparison is TortoiseGit revision
`7338078f8ddd924b8cddee35f512f2286072136d`, particularly
`TortoiseShell/ContextMenu.cpp` selection initialization and command dispatch, and
`TortoiseShell/MenuInfo.cpp` Log, Commit, ShowChanged, Diff, Clone and CreateRepo.
Those Explorer commands are not restricted to a previously watched-root list.
macOS Services supplies the missing selected-item entry point; its system menu
placement differs from Explorer and from TurtleGit's existing Finder Sync menus.
Services does not reproduce Explorer right-drag interception or per-entry shell
icons. Native operation windows retain their existing controls and source artwork.

The implementation follows Apple's
[Services properties](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/properties.html)
for file UTIs, required context, message/user-data mapping and restricted actions,
and its [service-provider lifecycle](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/providing.html).
Folder services advertise `public.folder`; the other four advertise `public.item`.
The bundle uses file services rather than treating a plain text path as a file.

## Validation and remaining acceptance

The batch adds Core selection/envelope checks and a grouped native fixture for
private-pasteboard dispatch, provider registration, startup/termination ownership,
captured repository routing and permission cancellation. The native runner is
`scripts/test-finder-services.py`; CI runs it with system and bundled Git.
The [batch evidence](qa/finder-services-family-2026-10-20.json) records the actual
executed scope and any failures. A focused local pass does not establish a hosted
CI pass or physical Services activation.

Physical Services registration, actual Finder/other-app menu gestures, localization
of Services menu declarations, signed sandbox selection access and App Store
acceptance remain unverified. Creation's early directory-type validation may need
adjustment if an installed signed Services invocation does not supply sufficient
selected-item access before the app's explicit permission chooser. System menu
visibility is separate from the existing Finder Sync activation and badge checks.
This family does not establish complete Explorer integration or whole-port parity.
