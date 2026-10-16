# Native Dock command progress

This ports the pinned Windows taskbar progress family to macOS. Reference:
TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`, `ProgressDlg.cpp`
normal/indeterminate/error/no-progress handling and `RebaseDlg.cpp` normal,
error, paused and completed states. macOS has one application Dock tile rather
than a taskbar progress button for each window. The native implementation uses
AppKit's [Dock content view](https://developer.apple.com/documentation/appkit/nsdocktile/contentview)
and [explicit display](https://developer.apple.com/documentation/appkit/nsdocktile/display()).

Clone, Push, Pull/Fetch, Merge, Abort Merge, Commit, Format Patch, Reset,
Switch, Stash Save and Rebase/Cherry Pick now publish their existing command
progress. The tile keeps the application icon and adds a green progress bar,
yellow waiting state or red failure state. Waiting/error symbols also distinguish
those states without relying only on color. Unknown progress animates a segment;
Reduce Motion keeps it static. No percentage is estimated when Git has not
reported one. The indicator does not alter the Dock's badge label.

A failed/cancelled result remains visible while its result window is open.
Successful completion removes its contribution, as source TBPF_NOPROGRESS does.
Rebase Edit/review pauses stay yellow; stopped/conflicted replay stays red.
Closing a retained window retires its entry immediately, even if its hosting
view/controller is still alive. A retired view cannot republish late changes.
Temporarily hiding a window keeps its entry. Shared streamed local commands own
an additional running entry until their producer and consumer drain, independently
of visible window lifetime. This covers other existing users of the shared stream,
including worktree and stash restore commands, for their active processing phase.
It does not add retained-result publication to every such consumer.

Concurrent operations share a deterministic native policy: any retained failure
wins; otherwise running work wins over an independently paused session. Among
running operations, any unknown percentage keeps the shared bar indeterminate;
otherwise it shows the least progressed operation. This is an explicit macOS
adaptation, not a weighted estimate of combined work or a claim to duplicate
multiple Windows taskbar buttons. Retiring one operation leaves the others intact.
No active entries restores the previous custom Dock content (or AppKit's normal
icon); cleanup never overwrites a later unrelated Dock-content owner. Animation
uses one timer, stops for known/paused/error/idle state and respects Reduce Motion.
Headless/test receivers do not modify the actual Dock tile. Application termination
clears the presenter.

## Acceptance scope

The Debug build and all eight grouped native cases passed on the first run,
with system and bundled Git. All eight receivers were reaped and independently
absent. Core was unchanged and not rerun. [Dated evidence](qa/dock-progress-2026-10-16.json)
records the scope and Xcode's exit-zero/no-output diagnostics. Native fixtures use private repositories,
preferences, injected Dock content, actual shipping progress views and real local
command/replay/Fetch regressions. Rendered tile samples are native view captures,
not proof of physical Dock display. Physical Dock minimization, auto-hide, multiple
displays, reduced-motion preference changes, VoiceOver, all progress consumers and
signed Finder/App Store execution remain open. No full dialog or application
parity is certified.


Eight actual tile-view light/dark renders were inspected. They show the current
unsigned app's generic macOS application icon; packaged branded AppIcon artwork
remains an explicit distribution/UI gap. These renders are kept as QA artifacts,
not advertised as a physical Dock screenshot or finished branding.


The [application identity family](APPLICATION-IDENTITY.md) now supplies a real
compiled application icon and patch-document icon. Its refreshed native tile
renders load the packaged AppIcon directly; the generic-icon finding above
describes the earlier bundle. Physical Dock/Launch Services acceptance remains
open.
