# Native utility ownership on application reopen

The installed build44 observation recorded a Cocoa reopen callback with
`hasVisibleWindows=false` and `workspace-request; mode=actionOnly`. Timing places
that callback about 56 ms after the About screenshot, during the computer-control
OK/AX operation; it does not establish that About was still open. A control-tool
reopen after Close can legitimately request the workspace. About's OK/Close
callback itself only retires its controller. The source review separately found
that retained/pending utility ownership was absent from the false-flag reopen
boundary; the controlled regression below exercises that active-owner case.
The application uses a Settings-only SwiftUI scene and an explicitly requested
AppKit workspace; there is no automatic WindowGroup
whose closure needs to be suppressed.

Reopen now consults retained native utility ownership before requesting a
workspace. About, Settings, Introduction, First Start, update checks and the
model-owned Autotext tester retain that authority through their real open
windows and synchronous creation gaps. Settings also retains its accepted-close
replacement gap. Native Debug acknowledgements and command errors also retain
ownership through actual open windows and queued acknowledgement/presentation
gaps. Reopen focuses an existing owner (including a minimized owner)
and never replays the command or constructs a replacement utility. A pending-only
owner keeps its original admission in progress. An explicit forced update retains
its accepted presentation intent through a held read. A quiet automatic network check alone does not fence workspace reopen
and does not create an update window.

The delegate scopes utility ownership around the actual CLI, URL and Services
activation/dispatch callbacks. A queued utility head also retains its pending
intent; Git configuration readiness, FIFO delivery and Quit admission keep their
existing gates. This covers activation callbacks arriving before the utility
factory has finished, as well as Cocoa's false window flag after presentation.

Actual Close/retirement releases the owning service/controller. A later Dock or
application reopen can create the normal workspace. Explicit workspace and Open
Repository requests remain independent user intents and can present that host
while a utility is open.

The focused native receiver uses real `WorkspaceSceneOwner`,
`WorkspaceWindowController` and native utility controllers in a private,
activation-prohibited process. Its hidden/offscreen checks cover false Cocoa
flags, reentrant About factory admission, utility Close, a real workspace
successor, explicit workspace presentation, warm Debug/error acknowledgements
and a real workspace reopen while a quiet update read is held. Original
utility/Git readiness, FIFO and local Merge assertions remain in their existing
cases.

The Debug build and the original utility-admission and corrected reopen cases
pass with system and bundled Git. Companion About, update lifetime, diagnostics
and Services checks pass within the scope recorded in the
[utility/distribution checkpoint](qa/utility-distribution-ownership-2026-10-31.json).
The [reopen receipt](qa/utility-reopen-2026-10-31.json) retains both earlier fixture
failures: repeated synthetic activation caused recursion during legitimate
post-close workspace presentation, and a quiet update request was incorrectly
expected to show a window. The corrected activation probe runs once, and the
visible-update case sends and asserts `/visible`; quiet/forced assertions remain.
All listed receivers were reaped and their private windows/work drained.

These checks do not reproduce Launch Services or a physical Dock click. The
original installed observation does not establish private preference isolation,
and its workspace geometry was restored separately. Signed installation and
physical acceptance of the repair remain separate from source/native checks.
