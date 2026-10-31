# Load Images and standalone image viewing

Reference: pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
TortoiseIDiff.rc `IDD_OPEN`, MainWindow.cpp `OpenDlgProc`, `AskForFile` and
`ID_FILE_OPEN`.

The app File menu offers Load Images without requiring a repository. Image
comparison windows have File → Open and scoped Cmd+O. The owned native chooser
has Left image and Right image path fields, individual Browse buttons, OK and
Cancel. The left current input is pre-filled; the right field starts blank,
matching the source dialog. A historical input is materialized from its captured
original bytes into a private immutable file, retaining its original path,
revision and object identity. Its filename is a bounded UUID plus a safe format
extension; repository names never become unchecked local filenames. Both empty sides, a single image and
two identical paths are accepted. Browse uses native single-file Open panels
with an image filter and other file types allowed. Typed paths support tilde
expansion; nonexistent/unreadable files display an inline error and retain the
chooser and prior viewer contents.

Accepting replaces the current image viewer inputs or opens a standalone viewer
from the app command. The viewer fits the new images, retains its overlay,
orientation, linking, image-info, width/height matching and alpha choices and keeps its window-owned
transparency background. Unsupported data remains in the image viewer with an
explicit decode message in ordinary panes; automatic Git text/binary routing remains unchanged.
Image inputs are read-only and follow file symlinks after access validation.

For AppStore, each nonempty external input requires a live file grant covering
its canonical location before reading. Only the exact app-owned historical copy
is exempt; the copy grants no authority to the repository or neighboring files. Browse retains the selected file lease. A
typed path without a suitable grant opens a file authorization picker, and its
cancellation prevents acceptance. Grants remain alive in the receiving viewer.
Owned chooser/picker cancellation and close/Quit fences retain modal ownership.
No file, Git index or repository mutation is part of this command.

## Verification and remaining work

The focused Core run passed 45 tests, including three new empty/single/duplicate,
symlink/read-only and invalid-input tests plus image/frame/conflict regressions.
The Debug build and bundle audit passed with 116 original icons. Native dialog
checks passed with system and bundled Git: actual Cmd+O, fields and OK/Cancel,
invalid-path recovery, identical/single/empty inputs, retained modes and fitted
replacement title. A missing typed-file grant opened the native authorization
picker; its Cancel prevented acceptance. An injected grant provider verified
that a pregranted standalone input retained its lease through viewer ownership and released it afterward. Close/Quit guards
and unchanged HEAD/raw index/file bytes passed. Native light/dark captures were
visually inspected. The receiver now runs a real prohibited-activation AppKit
event loop and requires its final PASS marker; earlier async-main runs exited
before completing the file-panel cancellation checks and were not accepted.
Existing comparison, color and playback regressions passed with both engines.
Final Core and native Open checks passed again after standalone error text,
error wrapping/width and empty regular-file decode labels were refined. Final
unsigned Debug and AppStore builds and bundle audits passed with 116 original
icons and required AppStore runtimes. This does not establish signing,
sandbox runtime acceptance or App Review eligibility. See the
[QA record](qa/image-open-2026-10-10.json).

That dated checkpoint did not cover historical-blob prefill; the October 31
implementation below supersedes the earlier empty-left behavior, with its own
validation scope. Physical Browse selection and text-entry gestures, VoiceOver,
signed file grants, all image formats/overlay decode states and retained layout
acceptance remain incomplete. Full image/application parity and App Store
acceptance remain open.

## Width/height matching on replacement

The native Open regression now uses a replacement with different pixel dimensions
and verifies that both matching controls remain selected across duplicate and
single-image replacement. This follows upstream `ID_FILE_OPEN` → `SetPic`: the
pictures and fitted zoom change, while the window's `bFitWidths`/`bFitHeights`
choices remain. See [the follow-up QA record](qa/image-open-sizing-2026-10-10.json).

## Native command surface — October 15, 2026

The connected [native image command family](IMAGE-COMMAND-PARITY.md) replaces
controller-hosted content tool rows with source-ordered AppKit toolbars and
native menu/overflow actions, common keyboard gates, full header tooltips and
stable model ownership across image replacement. See its dated evidence for
validation and remaining acceptance limits.

The October 16 connected tool-routing family makes explicit Load Images bypass
all external associations, both on initial opening and replacement. Automatic
comparison now uses the source image extension/tool policy; arbitrary-extension
image inputs belong to this explicit chooser. Explicit Merge Open and editor
replacement similarly retain the Merge route. See [tool dispatch](DIFF-TOOLS-PARITY.md#connected-imagetool-dispatch--october-16-2026).


## Captured inputs and asynchronous admission (2026-10-31)

Pinned `MainWindow.cpp:1197–1198` seeds Left from the current `leftpicpath`;
`ID_FILE_OPEN:441–461` replaces the pictures while retaining the window's mode
flags and fits them afterward. The native revision comparison stores repository
paths and bytes rather than an upstream temporary filesystem path. Open now
creates an owned read-only copy of those exact accepted bytes, instead of
leaving Left empty or resolving the historical path against today's checkout.
Original path/ref captions and the blob identity remain separate from private
storage authority. Cancelling Open deletes an unused copy; acceptance retains
it through subsequent Open/Reload and through any outstanding worker after
window retirement. Changed bytes, identical-byte inode replacement and symlink substitution are refused. Save and
Save As cannot overwrite the immutable seed, including existing hard-link or case aliases.

Seed preparation and authorized file reads run off the UI actor. A fixed
feedback band reports loading or an inline error without moving the path fields
or buttons; a long error remains available through help text. OK and Browse
cannot replace inputs while a read is owned. Cancel closes the chooser and
cancels its token; the requesting owner, permissions and Quit blocker remain
until the real read and native sheet release drain. Retired/cancelled callbacks
cannot accept a late result, display a late error or reopen a viewer.

Acceptance carries the exact validated document into the first viewer load;
it does not discard the read and reopen paths after chooser closure. Explicit
Reload subsequently reads live external files again, while verifying any
retained historical copy. The existing viewer, workspace command and standalone
image-tool Open all use this receipt handoff. Standalone replacement now seeds
from its current input and retains the current orientation, overlay/blend,
linking, alpha, dimension matching, image-info and appearance choices. Opening
new inputs fits them and requires a fresh Play command. Busy chooser admission
also blocks its existing viewer's frame controls.

The extended native Open fixture retains the prior dialog/picker/lease tests
and adds a real private revision comparison with different checkout bytes,
historical Cancel/accept/repeated Open, a non-native historical filename and protected-copy/inode/alias rejection, held reads
with external replacement before handoff, Cancel/drain/retry, late seed
retirement, stable control geometry under loading/long errors, and the actual
standalone Open replacement path. All original repository/index/source checks
remain.

The grouped Debug build passed. The complete Open fixture passed with system Git
(receiver 97963) after receipt installation moved before native host attachment.
The bundled-Git attempt then exposed an appearance ownership race; after the
explicit native-window attachment repair, the complete bundled fixture passed
(receiver 98556), including all retained mode flags, Dark Mode and decoded pixels.
The system pass predates that final attachment change and was retained without
repeating its unchanged input/read/receipt checks. This is cumulative scoped
evidence, not a claim that both engines ran the final source revision.

The retained failures led to three production repairs: an absent left side stays
blank instead of creating an unnecessary seed; accepted receipt bytes are
installed before the hosting view can admit its first appearance read; and image
presentation owns its native window before rendering, so appearance inheritance
does not depend on a later key-bridge mount. Native diagnostics retain caller
lines, named phases, read/owner state and individual source/replacement mode
values. Owned receivers were reaped and test windows/workers drained. The final
Debug rebuild passed. The combined dated QA record retains the original failures
and exact recheck scope. These checks do not establish signed deployment,
physical gestures, complete-format parity or a complete hosted CI pass.
