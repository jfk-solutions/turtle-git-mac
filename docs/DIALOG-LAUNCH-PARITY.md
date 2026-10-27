# Dialog launch ownership

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
TortoiseProc opens the requested operation rather than requiring a persistent
repository workspace. In the pinned source,
`src/TortoiseProc/Commands/AboutCommand.cpp` creates `CAboutDlg` and calls
`DoModal()` directly; `SettingsCommand.cpp` similarly opens its `CSettings`
property sheet for the captured path. TurtleGit retains a workspace as a macOS convenience; it
must not be a prerequisite for each native dialog.

## Entry points

| Request | Intended presentation |
| --- | --- |
| Finder About / Settings | Requested utility dialog, with no workspace created |
| Finder Log / Commit / other Git commands | Captured operation window after its required permissions and preparation |
| Primary `--command=…` / `/command:…` invocation | Requested dialog; malformed dialog input reports its error without opening a workspace |
| Finder Add to TurtleGit | Folder authorization if needed, then registration and initial badge publication; no workspace |
| Services → Open in TurtleGit | Explicit workspace entry for the captured selection, or repository chooser at that location |
| Normal application opening / explicit Open Repository | Workspace entry |
| Reactivation with an existing visible or minimized dialog | AppKit raises the existing window; no implicit workspace |
| Dock reopen with no visible windows | Restore the retained workspace |
| Existing Merge / Unified Diff tool invocation | Existing standalone tool, retaining its own save, output and process ownership |

### First-use permission and launch ownership — October 27, 2026

[Installed build17](qa/signed-consolidation-build17-2026-10-27.json) accepted an
actual private Finder folder grant, published modified/untracked badges and full
repository menus, and loaded the expected staged/unstaged Commit rows. It also
opened an unwanted empty workspace after the first-use permission picker. The
observation used an existing app binding without issuing an app reopen. The
precise AppKit callback responsible was not captured.

The [launch-intent continuation](qa/launch-intent-ownership-2026-10-27.json)
separates AppKit's automatic untitled fallback from explicit workspace entry,
fences callbacks before startup command delivery, and rechecks a queued normal
default-launch request against accepted URL/Service intent. Automatic setup and
update installation belongs to an attached workspace; delayed first-run setup
checks that host still exists. A later genuine Dock reopen and explicit Open
retain their workspace routes, including onboarding after an action-only launch.
An action that still owns permission, preparation or publication work also keeps
that ownership while no panel is visible; background workspace work does not
participate in this guard. Once the action drains, Dock reopen can open the host.
Bounded callback diagnostics omit paths and request payloads. Source/native
coverage and a subsequent signed physical first-use check remain distinct; the
source holes alone do not prove which callback caused build17's visible defect.

Opening a dialog must preserve any existing workspace's repository, selection,
window and in-flight operations. Folder registration must preserve unrelated
watches and the user's background-refresh preference. A path or URL is input,
not authority to read a repository. Cancelling folder authorization stops that
request; failures must be visible without relying on an otherwise hidden workspace.

## Implementation and verification scope

The action launch mode is selected before SwiftUI creates scenes. Finder supplies
that mode explicitly when launching commands. Utility and Git preparation use a
retained routing model without a repository window, with their existing permission
and cancellation owners. Explicit workspace requests retain their own route.

The public Services inventory is one restricted `public.item` entry, **Open in
TurtleGit**. Legacy typed handlers remain available internally; they no longer
produce dozens of duplicated public menu items. See [Finder Services](FINDER-SERVICES.md).

The implementation batch also carries the port author credit, **Jochen Kühner**,
and the existing green TurtleGit artwork. These identify the macOS port separately
from retained upstream attribution and do not establish App Store seller identity.

The [grouped checkpoint](qa/dialog-launch-2026-10-25.json) records four focused
Core inventory methods, the final Debug build and six distinct native case/engine
pairs cumulatively passing. It retains the earlier compiler, attribution-package
and fixture-permission failures and their repairs. Native checks cover cold/warm
About, Settings and Log, registration Cancel/retry and watch/recent persistence,
explicit workspace/public Open, handoff flags and dirty Settings Quit refusal.
Retained older launch checks additionally exposed a FIFO reentrant-delivery
regression; its source repair and production-only lazy-access initialization
were followed by affected launch, handoff, workspace/retirement, Merge, Unified
Diff and primary-entry checks. Stale fixture option/launch expectations were
corrected while retaining mutation and ownership assertions. All 18 receiver
PIDs, including failed attempts, were reaped and independently absent afterward.

Native receivers use private repositories/preferences and invisible windows;
they do not establish physical Finder gestures, signed permission grants or
visual parity of all upstream dialogs. Installed-application acceptance and cold
URL-launch limitations remain separate from injected receiver checks.

## Cold links, patch documents and the workspace host

The general application uses a Settings-only SwiftUI scene on macOS 13 and later.
A retained AppKit controller creates the workspace only for a default application
launch, explicit Open Repository/Open Recent, the public Open Service or Dock
reopen with no visible windows. Reactivating a general application with an
existing dialog lets AppKit handle that window without requesting a workspace.
AppKit includes minimized windows in the delegate's `hasVisibleWindows` flag;
the application does not replace that flag with an `isVisible` scan. Explicit
workspace requests remain independent of this automatic reactivation policy.
See the [AppKit reopen contract](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldhandlereopen(_:hasvisiblewindows:)).
AppKit's `launchIsDefaultUserInfoKey` supplies the initial launch intent;
there is no timeout that guesses whether a URL will arrive. See the
[AppKit launch metadata](https://developer.apple.com/documentation/appkit/nsapplication/launchisdefaultuserinfokey).

A cold `turtlegit://` action or `.patch`/`.diff` document uses the retained routing
owner without creating the repository model or workspace controller. Requests
received before startup are queued and delivered in order. Closing and reopening
the workspace retains its model and child operation ownership. The native toolbar
keeps Open, Refresh, Commit and Show log, with repository/busy eligibility. Settings
drafts are settled before the shared Settings service changes to the workspace;
the action owner retains a separate service afterward.

The [follow-up grouped checkpoint](qa/workspace-launch-2026-10-25.json) passed
Debug and nine focused native checks: cold file, late URL and workspace ownership
with system/bundled Git, retained primary dialog routing with both engines, and
the dedicated Merge scene/menu lifecycle. Receiver processes were reaped and
independently absent. These checks inject launch metadata; they do not certify
physical Launch Services delivery or migration of previously saved window state.
The installed build3 acceptance below describes the preceding candidate.

## Dialog reactivation and utility Close — 26 October 2026

The [grouped checkpoint](qa/dialog-reactivation-2026-10-26.json) covers the
general application's visible-window reopen route and the retained workspace,
plus Merge's custom Close command for About and scoped Settings. Four native
case/engine pairs pass cumulatively: action launch with system/bundled Git,
retained workspace ownership with system Git, and Merge utility/menu ownership.
Actual About/Settings/Log windows, a dirty Settings draft and its warning sheet,
and a Commit draft with its own sheet and minimized window retain their owners.
Explicit Open still presents the workspace; no-window Dock reopen retains the
same workspace controller. Commit HEAD and semantic index remain unchanged.

The initial build emitted contradictory zero-exit Swift diagnostics; the
incremental recheck is clean. Native verification first required an explicit
sheet completion-handler overload. Later attempts reached the activation
assertions but exited before cleanup completed. A diagnostic stack identified
AppKit handling AEQuit during asynchronous receiver cleanup; its sender and
trigger are unproven. A private receiver lifetime delegate now declines that
external Quit until verification drains. Direct production Quit assertions,
actual minimization and completion markers remain required. Every attempted
receiver was reaped and independently absent.

These are offscreen checks of current Debug objects, not physical Dock/keyboard
acceptance or a replacement of installed build11. Rebase child reactivation,
physical accessibility and the next signed distribution remain unverified.

## Installed application acceptance — 25 October 2026

The signed universal Apple Development build3 was installed after the prior user
session had closed. All 6,356 installed files match the measured candidate; app,
Finder and cache identities agree, and the Finder registration was refreshed
while retaining its enabled preference. The previous bundle is recoverable.

A normal-environment installed `--command=about` launch visibly showed the
standalone About dialog, green TurtleGit banner, Jochen Kühner port credit and
packaged Git2.55.0 version/path. The first private-home acceptance attempt did
not complete and was cleaned up; CUA also created/exposed a normal launch that
was closed before the clean retry. These attempts and all process cleanup are
recorded rather than counted as successful physical checks. No acceptance app
remains running. This covers application About, not physical Finder grants,
all tool layouts, a live Dock-cache inspection or App Store distribution.

## Follow-up installed acceptance — build4

The universal Apple Development build4 passed strict signature checks and was
installed with all6,356 files matching the measured candidate. Its source input
digest is `fb3c59b7da7afefe72796eea54038427aacd1848a62a7621847202fcb5503f68`.
One enabled Finder registration points to the installed extension.

A real cold Launch Services request for `turtlegit://action?command=about`, with
no special launch arguments or injected metadata, visibly opened the About
dialog, green TurtleGit banner and version0.1.0(4); no workspace was observed.
The acceptance process was closed with Command-Q, its waiting launcher exited0
and the application PID was independently absent. This complements the private
receiver checks; it is not exhaustive acceptance of saved-state migration, every
external action, physical Finder grants or all upstream layouts.
