# Native Windows metafile consumers

Pinned TortoiseGit source: `7338078f8ddd924b8cddee35f512f2286072136d`.
This documents the native consumer portion of the WMF/EMF/EMF+ renderer batch;
it does not certify every IDiff format, source control or physical interaction.

## Source and native routes

`src/Utils/MiscUI/Picture.cpp:402–449` loads captured image files through GDI+
(including Windows metafiles), retaining IDiff's normal panes and picture state.
`src/TortoiseIDiff/MainWindow.cpp:183–195` installs two comparison panes or
Mine/Base/Theirs conflict panes. The source Open filter at line 1255 explicitly
includes `*.wmf` and `*.emf` alongside ordinary image extensions and All Files.

The macOS port keeps its existing image scroll/canvas, toolbar, zoom, overlay,
frame controls, metadata and selection workflows. It passes original bytes to
Core's cancellation-aware ComparisonImage decoder; Windows metafile rendering is
provided by the separately documented packaged helper. It does not convert the
repository file, replace conflict stages, or substitute the raster into Save or
Select operations.

FileComparisonWindow's captured viewer selection remains authoritative. A
configured/default image route stays IDiff even if one or both sides cannot be
decoded. Explicit Merge remains Merge and never invokes the image decoder merely
because its inputs contain image bytes. Empty sides and malformed/unsupported
metafile records continue to display the existing undecodable-side placeholder.

## Ownership and publication

Two-side image decoding now runs off the main actor inside the accepted
FileListComparisonSession. That session, its cancellation and captured permission
leases survive through the actual decoder completion. The original document and
new image panes are published together only after the token and current session
are rechecked. Closing or retiring the viewer cannot publish a delayed image or
replace a newer document.

Dropped files are read and decoded before preview publication. The accepted drop
retains its own file grant, token and generation until the decoder drains. Input
replacement, a newer drop or owner retirement cancels the old receipt; a late
result cannot overwrite the current preview. The existing activeFileReads counter
includes decoding as well as disk reads. Unsupported images are still valid
preview inputs with their original bytes, independently of rendering success.

Three-side conflict initialization and Reload are also owned asynchronous decode
phases. Busy state and activeOperations cover all three sides and actual decoder
retirement. Ordinary window Close and Escape remain available during preview
decoding: closing immediately retires the window and cancels its decoder while
the model, repository access and Quit counter survive until actual drain. Close
still refuses busy Select/mutation work and attached questions. Original stage
bytes remain available for Select even if rendering
fails. A late initial or reloaded decode after close cannot replace the captured
conflict document, images or panes. The existing mutation/resolution workflow is
unchanged; preview decoding alone never stages or writes the conflict file.

The Load Images chooser explicitly includes WMF/EMF filename UTTypes rather than
relying solely on LaunchServices' public.image inheritance. It retains the
source All Files behavior and its per-file authorization checks. Chooser and file
panel inherit actual owner appearance/alpha. Accepted Open only reloads after
its sheet and any file panel actually detach. The activeReleases counter fences
Quit during this handoff; cancelled or retired owners cannot launch a late reload.

## Focused verification and limits

`qa/metafile-consumers-native-2026-10-18.swift`, entry
`MetafileConsumersVerification.verify()`, accepts a private workspace, Git path
and `Tests/TurtleGitCoreTests/Fixtures/Metafile` directory. It selects the six
original representative 96×64 successful corpus files explicitly; the painting
extension adds `plus-gradient-transform.emf` and `plus-image-attributes.emf`.
Extra physical-geometry
or DPI fixtures belong to the Core renderer checks. It also checks the explicit
unsupported-record fixtures in IDiff without requiring an image result.

The new receiver covers default extension dispatch, actual native image panes
and dimensions, unsupported-side preservation, forced Merge non-decoding,
preview-only drop/Reload, actual Load Images acceptance and detach, three-side
WMF/classic EMF/EMF+ conflict initialization/Reload, and unchanged original file,
HEAD/index and conflict bytes. Noncooperative injected decoder holds verify main
actor availability, session/grant/Quit lifetime, superseded-drop handling and
initial/reload cancellation through actual performClose and Escape without
weakening production permission checks.
Every test-owned window stays invisible/offscreen, and failure cleanup resumes
held decoders, retires owned models and waits for the actual counters.

Retained image conflict, frames, colors, toolbar and owned-conflict receivers now
wait for the initial asynchronous decode before their existing native assertions.
The [grouped evidence](qa/metafile-workflows-2026-10-18.json) records actual checks,
fixture corrections, the user-close repair and an unresolved intermittent EMF+
consumer assertion. Complete WMF/EMF record coverage and exact GDI+ equivalence,
all animation/vector formats, physical keyboard/VoiceOver/drag gestures, current
hosted CI, signed sandbox grants and compositor screenshots remain separate
acceptance work.

## Painting extension

The [EMF+ painting batch](METAFILE-PAINTING-PARITY.md) extends the decoder used by
these same panes. Default ImageAttributes, gradient objects and additional image
destination encodings do not select a different viewer, add authority to a dropped
file, or change conflict/save bytes. These additions require their own recorded
Core painting and native consumer evidence. The earlier consumer passes and the
unresolved intermittent observation above remain historical evidence, not proof
of the new painting subset or an explanation of that observation.

Gradient brush paint is a bounded intrinsic-resolution display PNG with vector
fill clips or a text luminance mask. Preview zoom can enlarge that paint raster;
it does not recreate a resolution-independent gradient. Bitmap wrapping uses
explicit visible copies rather than native SVG patterns. These renderer repairs
preserve the same decoded-image publication, original-byte and cancellation
contracts described above. Initial painting failures and focused repairs must
remain in the [current batch evidence](qa/metafile-painting-2026-10-18.json).
The final consumer group passed with system and bundled Git; both owned receiver
processes were reaped and independently absent afterward.

Visible bitmap tiles additionally reserve their projected inline markup against a
64 MiB aggregate limit before construction. Excessive Float32 uncertainty in a
radial boundary is an unsupported side, preserving the ordinary undecodable-side
policy. Core painting pixel inspection uses explicit sRGB bytes rather than
profile-losing `NSBitmapImageRep.colorAt` access; the existing color thresholds
remain unchanged. All 18 metafile Core methods passed after these repairs.
Hosted integration, physical Windows equivalence and current signed distribution
acceptance remain separate.
