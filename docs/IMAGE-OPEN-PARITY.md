# Load Images and standalone image viewing

Reference: pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
TortoiseIDiff.rc `IDD_OPEN`, MainWindow.cpp `OpenDlgProc`, `AskForFile` and
`ID_FILE_OPEN`.

The app File menu offers Load Images without requiring a repository. Image
comparison windows have File → Open and scoped Cmd+O. The owned native chooser
has Left image and Right image path fields, individual Browse buttons, OK and
Cancel. Only the left usable working-file path is pre-filled; the right field
starts blank, matching the source dialog. Both empty sides, a single image and
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

For AppStore, each nonempty input requires a live file grant covering its
canonical location before reading. Browse retains the selected file lease. A
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

Physical Browse selection and text-entry gestures, VoiceOver, signed file grants,
all image formats and overlay decode errors, retained layout and
historical-blob left-path prefill remain incomplete. A historical comparison
without a usable absolute filesystem path currently starts with an empty left
field. Full image and application parity and App Store acceptance remain open.

## Width/height matching on replacement

The native Open regression now uses a replacement with different pixel dimensions
and verifies that both matching controls remain selected across duplicate and
single-image replacement. This follows upstream `ID_FILE_OPEN` → `SetPic`: the
pictures and fitted zoom change, while the window's `bFitWidths`/`bFitHeights`
choices remain. See [the follow-up QA record](qa/image-open-sizing-2026-10-10.json).
