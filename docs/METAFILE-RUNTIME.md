# Packaged WMF / EMF / EMF+ renderer

TurtleGit packages `metafile-convert` and `renderer.js` in
`Contents/Helpers/Metafile` (the finalized application layout relocates executable
code and preserves the logical helper alias). It does not require Homebrew, Node,
npm, an installed Office application, or a network conversion service.

The renderer is [WmfEmfViewer](https://github.com/congduan/WmfEmfViewer), package
`wmf-emf-renderer` 0.2.1, pinned at
`4e0d6d6807349ebfc8f8c681009c14f9e57621ff` under the MIT license. The archive
URL and SHA-256 are in `Configuration/MetafileRuntime.json`. Local compatibility,
state, clipping, font, and unsupported-record changes are reproduced by
`patches/metafile-renderer.patch`; the patch is part of the provenance input.
libwmf/libemf2svg were evaluated but are not linked or shipped: their SVG backends
contain unimplemented drawing callbacks, including EMF+ drawing in libemf2svg.

The [region/pattern extension](METAFILE-REGION-PATTERN-PARITY.md) adds Wine’s
LGPL-2.1-or-later hatch cells at pinned commit
`7298a818b79446bae153b8d5aa27235ab3703bf9`. The isolated adapted table and original
copyright accompany the patch; `LICENSE-Wine-hatches` and NOTICE accompany the
runtime. Its full source hash, license hash and origin are pinned separately in
Configuration/MetafileRuntime.json. No Wine binary is linked or shipped.

The [classic clipping extension](METAFILE-CLASSIC-CLIP-PARITY.md) adapts the
MIT-licensed BaseHmiTypes renderer's region-combine and metaregion/offset mask
lifecycle. Its immutable revision, original source hash and retained license hash
are recorded in `Configuration/MetafileRuntime.json`; `LICENSE-BaseHmiTypes`
accompanies the helper and its corresponding reconstruction sources. It adds no
runtime package dependency.

The [EMF+ pen extension](METAFILE-PEN-PARITY.md) connects pen object parsing to
native stroke outlines for the nine drawing record families. The existing brush
pipeline paints solid, gradient, hatch and texture strokes. Linear pen transforms,
compound bands, caps, joins, dashes and Center/Inset positioning have their own
explicit scope and remaining compatibility list.

## Rebuilding and embedding

Run `python3 scripts/build-metafile-runtime.py`; the default output is
`build/metafile-runtime/Metafile`. `--output PATH` chooses a different recognized
runtime output. The build needs the Xcode command line tools and Python 3; it
resolves only static, relative CommonJS imports into a deterministic module table,
without downloading executable npm build tools. The universal helper contains
arm64 and x86_64 slices targeting macOS 13 and links system JavaScriptCore,
CoreText, CoreGraphics and ImageIO. Before creating its JavaScriptCore VM the
helper sets `JSC_useJIT=false`, using the interpreter without an allow-JIT or
unsigned-executable-memory entitlement, following [WebKit’s interpreter
configuration](https://webkit.org/blog/6411/javascriptcore-csi-a-crash-site-investigation-story/).
Runtime font metrics and [formatted text glyph outlines](METAFILE-TEXT-PARITY.md) use CoreText; raw GDI+
BGR/BGRA bitmaps are converted to PNG using ImageIO. Platform font substitution
can differ from Windows when an original font is unavailable.

The reconstruction cache incorporates pins, all build/adapter/patch script hashes,
architecture/deployment flags, compiler version and SDK version. Each runtime
contains the original source archive, exact local reconstruction inputs, MIT,
BaseHmiTypes MIT, Wine hatch LGPL and application licenses, binary/renderer/source/license hashes and toolchain metadata.
`python3 scripts/validate-metafile-runtime.py PATH` verifies those inputs and
reconstructs the renderer, checks slices/deployment/linkage, and executes a bounded
conversion and malformed-input checks. `--all-architectures` executes both slices
when the host supports them. `--structure-only` is used during embedding and does
not claim conversion acceptance. End-to-end native family fixtures provide the
WMF/EMF/EMF+ drawing evidence separately.

`python3 scripts/embed-metafile-runtime.py RUNTIME APP` copies a validated runtime
and signs its helper before the containing application. App Store builds apply
the existing inherited-sandbox helper entitlements. A signed inherited helper
requires invocation by its sandboxed parent; standalone structural validation does
not prove signed distribution or App Store acceptance.

## Process contract and limits

The helper accepts exactly `--wmf` or `--emf`, reads binary standard input up to
64 MiB, and writes SVG standard output up to 128 MiB. Diagnostics go to stderr;
invalid input, mismatched formats, unsupported painting and failed native adapters
return nonzero without an SVG. The owning application supplies cancellation and a
15-second wall-clock limit, drains the exact child process, and reads output away
from the main thread. Input is not a filename or an authority grant. The helper
exposes no filesystem, DOM, Canvas, HTTP, module loader or process API to the JS
renderer. Bundled JS is loaded from the signed application resource location.

TextDecoder supports UTF-8, UTF-16LE, Windows-1252, Shift-JIS, EUC-KR, GBK/GB18030
and Big5. The bitmap callback accepts GDI+ RGB24, RGB32, ARGB32 and PARGB32 with
signed stride; the [bitmap extension](METAFILE-BITMAP-FORMATS-PARITY.md) also supports indexed palettes and RGB555/RGB565/ARGB1555. Oversized or malformed buffers are refused. Raster output is
limited to 16,777,216 pixels. Unsupported drawing must fail explicitly rather than
presenting a successful blank or incomplete comparison. This is a renderer port,
not a claim of bit-exact Windows GDI/GDI+ coverage; unimplemented source records,
font substitution, complex composition and physical visual acceptance remain
tracked by the image-comparison parity documentation.

## Painting compatibility inputs

The [painting extension](METAFILE-PAINTING-PARITY.md) adds bounded parsers and
painting within the same captured-byte helper contract. Native CoreSVG does not
reliably implement the required gradient spread/colors or bitmap patterns, so
actual gradient paint uses analytically evaluated embedded PNGs with vector
clips/text luminance masks. SVG gradient definitions remain metadata. Each paint
raster is limited to 16,777,216 pixels/64 MiB raw data, with 67,108,864 generated
gradient pixels per conversion. Device paints use intrinsic pixel-center
sampling; the native consumer supplies an explicit intrinsic-size sRGB destination
instead of assuming a particular CoreSVG backing scale. Bitmap wrapping emits only visible image copies,
capped at 16,384 tiles per record and 65,536 per conversion. Before concatenation,
each tiled record reserves `count * (escapedPNGhref.length + 4096)` against a
64 MiB aggregate markup budget, preventing count-valid data-URI amplification.
Radial canonical-shape/Float32 uncertainty above 100 ppm of the conservative
minimum axis is refused before painting. RGB color plus
separate opacity avoids the observed native RGBA alpha ambiguity. These display
rasters have intrinsic output resolution; preview zoom is not unlimited vector
gradient rerendering. It retains the MIT
renderer pin and private adapter provenance; gradient/image-attribute support
must not introduce a browser, Node runtime or document-provided module loading.
Changes to local reconstruction inputs require a new runtime provenance/cache
identity. Existing standalone execution evidence below predates this extension
and does not validate its new records, pixels or platform raster output. The
[painting checkpoint](qa/metafile-painting-2026-10-18.json) separately records the
latest reconstructed universal runtime, successful Debug app build, 18 passing
metafile Core methods and native consumer passes with both Git engines on the
local arm64 host. It is not a full Intel painting-corpus execution result.

## Recorded standalone checkpoint

On 2026-10-18 the universal runtime built successfully, and its reconstruction,
macOS 13 load commands, SDK-only dependencies, actual simple WMF rectangle
conversion and malformed/format rejection checks passed on both arm64 and x86_64.
The same execution checks passed on a private ad-hoc hardened copy without
allow-JIT or unsigned-executable-memory entitlements. That copy was removed after
validation. Local log: `build/qa/metafile-runtime-2026-10-18.log`. This focused
checkpoint does not establish the full EMF/EMF+ fixture matrix, native comparison
integration, physical visual parity, Developer ID notarization or inherited
sandbox invocation; those require their own recorded grouped evidence.
