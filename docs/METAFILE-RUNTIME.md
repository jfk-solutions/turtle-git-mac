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
Runtime font metrics use CoreText; raw GDI+
BGR/BGRA bitmaps are converted to PNG using ImageIO. Platform font substitution
can differ from Windows when an original font is unavailable.

The reconstruction cache incorporates pins, all build/adapter/patch script hashes,
architecture/deployment flags, compiler version and SDK version. Each runtime
contains the original source archive, exact local reconstruction inputs, MIT and
application licenses, binary/renderer/source/license hashes and toolchain metadata.
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
signed stride and rejects indexed/16-bit/oversized buffers. Raster output is
limited to 16,777,216 pixels. Unsupported drawing must fail explicitly rather than
presenting a successful blank or incomplete comparison. This is a renderer port,
not a claim of bit-exact Windows GDI/GDI+ coverage; unimplemented source records,
font substitution, complex composition and physical visual acceptance remain
tracked by the image-comparison parity documentation.

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
