# EMF+ untouched pixels and explicit display backgrounds

This continuation follows the pinned TortoiseGit Picture file-load consumer at
`7338078f8ddd924b8cddee35f512f2286072136d`. The original Windows image-effect
recordings load their EMF+ files with `Bitmap(file,FALSE)` and replay them with
SourceCopy into a transparent output. Their captured RGBA distinguishes untouched
pixels from explicit white paint. No new Windows execution or pixel oracle was
manufactured for this continuation.

## Rendering and consumers

Recorded Plus-only and dual-stream files now begin with transparent, unpainted
allocation. The renderer no longer inserts a full white rectangle before their
records. Classification uses the validated Plus Header rather than the outer
parser's `emf` label. Embedded objects retain their existing transparent path;
classic EMF and WMF retain their separately documented DC initialization.

Actual paint remains actual paint: opaque or semitransparent Graphics.Clear,
white brushes, opaque text backgrounds, GDI coverage after GetDC, and later
SourceOver/SourceCopy operations keep their recorded behavior. Clear still covers
the complete natural allocation independently of compositing mode. Removing an
initial matte does not remove white from a coverage mask or change Boolean GDI
operands. Untouched pixels outside those operations remain transparent.

Compare, conflict panes and shared image-raster operations receive that original
alpha. A chosen Transparent Color is a display backdrop; changing it does not
rewrite the metafile or replace its decoded source pixels. Save/resolve continue
to use original inputs and their existing owned-operation rules.

## Original Windows evidence and test surfaces

The image-effect reference generator previously replaced 459 unpainted captured
samples with an opaque-white compatibility expectation. Each now uses its actual
retained `windowsRGBA`; the former value is preserved as `legacyCompatibilityRGBA`
for history. Covered samples, source EMF bytes, refusal wires and tolerances are
unchanged. Nine original raw planes are copied byte-for-byte into
`Tests/TurtleGitCoreTests/Fixtures/Metafile/ImageEffects/Windows`, after verification
against the already retained raw/source SHA-256 values. Its manifest records the
original run, artifact, archive hash and source/raw identities.

The full-buffer Core comparison checks every pixel against those captures in
premultiplied form, with the existing per-channel tolerance of 3 and exact
zero alpha where the Windows alpha is zero. Separate literal-record controls
cover empty Only/Dual streams, state-only records, half-alpha paint, explicit
Clear and interleaved GetDC. These authored controls are identified as arithmetic
and record-contract checks, rather than additional Windows captures.

Older pen, text, hatch and palette geometry tests intentionally compare display
colors on white. Their test-only helpers now explicitly create a white CGContext
before drawing and are named accordingly. Their existing geometry, antialias,
color and coverage assertions remain. Separate raw-output assertions protect
half-alpha bitmap/hatch output, invisible color channels, transparent indexed/
ARGB pixels, and ink/margins. Raw embedded pixels, Windows references, GDI Boolean
and transfer checks are not flattened to make them pass.

Pointwise and spatial-effect references already derive their samples and full
buffers directly from native output; their expected pixels remain unchanged.

## Checkpoint and remaining scope

[The dated record](qa/metafile-initial-alpha-2026-10-29.json) records the
universal helper reconstruction, successful native build and 226 distinct Core
methods cumulatively passing. The broad 226-method run retained 35 assertions in
three new fixture checks that incorrectly assumed no recorded white paint; those
three methods passed their focused source-record repair. The earlier integer
conversion compile failure is also retained. No clean repeat of the entire group
is claimed.

All six image/pointwise/spatial native case/engine pairs passed with system and
bundled Git after a shared-reference initializer compile repair. Compare/conflict
background choices, exact source-alpha preservation, shared raster output,
reload/retirement and original-byte Git resolution remain asserted. All six owned
receivers were reaped and independently confirmed absent; no helper survived
completion. Native acceptance
uses private repositories and preferences, invisible owned dialogs and injected
responses; it does not establish physical clicks, signed sandbox execution,
Intel/minimum-macOS execution or every undocumented paint state. Classic file
initialization remains a separate policy and is not silently reclassified by this
Plus-stream correction. Installed build31 predates this change.
