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
| Existing Merge / Unified Diff tool invocation | Existing standalone tool, retaining its own save, output and process ownership |

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

## Remaining entry-point gap

A third-party application that cold-opens a raw `turtlegit://` action URL without
TurtleGit's launch argument can still cause SwiftUI's default workspace scene to
appear. The shipped Finder launcher and primary command-line dialog entry choose
the action-only scene explicitly. Warm URL delivery is separated from workspace
presentation. Eliminating the arbitrary cold-URL case across macOS 13 and later
remains a distinct scene-startup gap; it is not counted as covered by injected
URL delivery after startup.

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
