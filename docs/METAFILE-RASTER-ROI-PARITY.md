# Bounded metafile raster regions and ordered checkpoints

Image Compare and image-conflict panes use the same private WMF/EMF decoder.
This continuation preserves the [Boolean and masked-transfer contract](METAFILE-RASTER-PARITY.md)
while reducing repeated work for small operations. The pinned Windows app loads
these pictures through GDI+; this is an implementation of that ordered drawing
behavior on macOS, not a new dialog or a claim of Windows pixel identity.

## Drawing coordinates and validation

Bitmap transfer bounds include all four transformed destination corners, a
conservative one-device-pixel antialiasing halo and intersection with the device
canvas. Mirrored and sheared destinations retain their original mapping. Native
operand rendering translates the original canvas into the bounded region; it
does not resize the viewport or reset source, brush or mask coordinates.
Source and mask device planes sample at the same global pixel centers as before,
including source-edge clamping and repeating-mask phase. Only covered region
bytes are installed into the destination; bytes outside it are retained.

Ordinary transfers with retained RGBA pixels share the inverse-mapped source
sampler used by masked/transparent transfers. This keeps source-image edge
antialiasing from becoming a second coverage mask on an affine destination.
Compressed direct-scanline receipts that retain only an embedded PNG use their
existing SVG source path and device-aligned, nonstretched placement.

Unknown vector stroke/fill bounds retain full-canvas playback. Flood coverage
still inspects destination connectivity across the canvas. This change does not
replace either operation with an approximate bitmap rectangle.

Offcanvas transfers validate declared bitmap framing, required source rectangles,
masks, patterns and transforms before returning without painting. An empty
intersection cannot hide malformed input. Unsupported input continues to refuse
the complete picture through the existing image-loader failure path.

## Checkpoint lifetime and serialization

The native compositor retains one current, native-produced RGBA canvas inside a
single conversion. Its receipt carries a fresh identity and exact dimensions.
The renderer requests reuse only when the destination consists of the unchanged
single node associated with that receipt. Intervening ordinary vector/text
drawing invalidates that condition and requires destination rendering again.
A stale native receipt is an error. There is no cross-conversion cache.

Each SVG snapshot serializes its reachable definitions, their transitive
references and referenced image placeholders. The live definition and image
arrays are restored after serialization, including on failure. SaveDC/RestoreDC,
later object selections and deleted/reused handles therefore retain their
existing object-lifetime semantics. The final SVG uses the same serializer so
abandoned intermediate images do not remain in its markup.

All SVG operands still pass the independent native policy check, even when the
destination receipt is reused. Full-canvas cumulative work charges and existing
input/output, memory, call and markup bounds remain in effect. The decoder's
15-second deadline and all truth-table assertions remain unchanged. This is a
performance change within those bounds, not a larger acceptance limit.

## Verification boundary

The initiating hosted failure is
[run 39533313374](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/39533313374):
five assertions failed across three full truth-table methods. MASKBLT explicitly
timed out; the failable EMF BITBLT and WMF DIBBITBLT readers returned no image
without exposing their underlying cause. The new implementation must retain all
256 ROP3 and foreground/background ROP4 truth cases rather than shortening those
fixtures or raising the timeout.

Authored ROI scenes exercise asymmetric device placement, affine/mirrored source
sampling, interleaved vector painting, saved brush/clip references, mask phase,
offcanvas malformed input and conversion isolation. Actual decoded pixels are
the oracle; source text and successful helper exit alone are insufficient.
Native consumer checks retain original-byte comparison/conflict behavior and
private worker/window drainage. The [dated batch evidence](qa/metafile-raster-roi-2026-10-21.json)
records actual executions and repairs, including failures; its scope does not
certify a complete hosted run.

Complete Windows graphics compatibility, exact antialiased edge/font behavior,
physical Finder activation, signed replacement and a complete current hosted
pass remain separate acceptance work.
