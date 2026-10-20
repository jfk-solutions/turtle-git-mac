# Positioned metafile text in image comparison

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
Its image viewer accepts Windows metafiles through GDI+. This connected family
adds positioned text to the existing macOS decoder used by comparison panes,
dropped previews and image conflicts. It complements
[formatted DrawString layout](METAFILE-TEXT-PARITY.md), whose shaping and wrapping
contract is separate from caller-positioned glyphs.

## Record and font contract

Microsoft's [DrawDriverString record](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/b794b780-e9a8-4682-af65-9b614aecfbe6)
distinguishes character-map values from font-specific glyph indices. The decoder
must preserve that distinction: a glyph index cannot become a Unicode character.
The wire array contains a position slot for each input value. RealizedAdvance
uses the initial position and native advances; it does not shorten the serialized
array. An optional six-component matrix follows the complete arrays.

The [driver options](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/d21f08ce-2fd4-49f2-9796-b41e93d1d7d5)
also distinguish vertical output and a raster-cache quality hint. CoreText supplies
native font outlines and advances. Caller-positioned text must not receive the
paragraph shaping, wrapping or implicit reordering of DrawString. Raw glyphs
require the requested installed font; substituting an unrelated font would change
what the indices mean. Font availability and exact Windows glyph metrics remain
independent compatibility limits.

The driver matrix acts on font geometry and advance vectors about each supplied
origin. Graphics-world mapping acts on positions separately. Ignoring the driver
matrix's translation follows the inspected Wine GDI+ implementation, which builds
font vectors from that matrix. For vertical output, its Prepend composition
applies the driver linear transform before the clockwise quarter turn. A
noncommuting transform must distinguish that order from turning first. These
interpretations have no independent Windows capture yet and must not be
described as pixel-certified Windows playback.

Classic EMR_EXTTEXTOUTW uses the selected LOGFONT and
[EmrText](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/dd585d0a-5d7c-4034-963a-1141af836972)
offsets. Its optional spacing array affects actual character origins. ETO_PDY
provides paired horizontal and vertical advances. The complete buffer extents,
alignment and record-relative offsets must be checked before font work. Source
alignment, background and clipping belong to the same text operation, with
current-position state preserved through graphics Save/Restore.

[SetTextAlign](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-settextalign)
makes the saved current position the reference when TA_UPDATECP is set. The
inspected [Wine font implementation](https://github.com/wine-mirror/wine/blob/840a939ee526137639665ff5f587224d6a36403f/dlls/win32u/font.c#L5993) advances it to the right edge
for left alignment, moves it to the left edge for right alignment, and retains
it for centered alignment. Vertical baseline adjustment does not change this
continuation point. Fixtures must distinguish these cases rather than testing
only a single left-aligned string.

The selected [LOGFONT](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-logfontw)
distinguishes cell height from em height, and escapement from glyph orientation
in advanced graphics mode. An explicit average width scales font vectors using
the selected font's [OS/2 average-width metric](https://learn.microsoft.com/en-us/typography/opentype/spec/os2#xavgcharwidth).
Actual glyph advances still come from CoreText; the average metric does not
replace each glyph's width. Missing or invalid required font metrics must cause
an explicit refusal. Native scalable-font metrics do not certify Windows font
mapper selection, raster-font sizing or device-specific rounding.

## Shared native ownership

The existing helper remains the only conversion process. Positioned glyphs share
the formatted-text conversion's aggregate input, glyph, outline and serialized
path budgets. Repeated records cannot acquire fresh per-record work allowances.
Native outlines return through the same JavaScriptCore boundary without exposing
font-file paths, filesystem, network or executable access to the document.

The existing image operation owns cancellation and process drain. Original
repository, preview and conflict bytes remain unchanged; outlines are private
display data. Text decorations, brushes, clipping, transforms and bounds must be
reviewed together rather than accepting a valid-looking but incomplete string.

## Accepted scope and explicit limits

Driver output supports supplied positions, RealizedAdvance, Unicode character-map
lookup or raw glyph indices, vertical rotation, linear matrices, existing brushes
and captured graphics clips. LimitSubpixel is retained as a quality hint; vector
outlines have no GDI glyph bitmap cache to reduce. Valid surrogate pairs map to
one glyph cluster at the first UTF-16 position, while malformed pairs fail.
Raw glyph output requires an installed matching face and style. Unicode lookup
can use native font substitution but receives no paragraph shaping.

Classic W output supports ETO_OPAQUE, ETO_CLIPPED, ETO_GLYPH_INDEX, ETO_PDY and
the ETO_IGNORELANGUAGE metadata flag. Each supplied displacement contributes,
including the final advance used for alignment and continuation. Positive PDY
moves upwards in source font coordinates. Advanced graphics mode retains affine
geometry and independent escapement/orientation; compatible mode compensates
reflected device axes. Compatible font ink and native advances use the font's
vertical device scale, independently of the full mapping of supplied spacing.
The glyph and layout compensation matrices preserve those separate rules.
Record exScale/eyScale remain finite conversion metadata; ExtTextOutW playback
does not apply them again over the captured device context. Explicit rectangle backgrounds and clipping use ordered
device corners. An opaque background without an explicit rectangle uses the
native cell metrics. Transparent BeginPath text accumulates glyph outlines.

Opaque BeginPath text, empty driver records, locale/numeric/RTL text options and other classic record
variants remain outside this implementation. The retained ANSI path refuses
glyph-index input explicitly. Native font metrics, vertical-specific CJK forms,
Windows-only font families, bitmap/color-only glyphs and exact GDI rasterization
remain compatibility limits. A refusal returns no successful partial image.

Each positioned call is limited to 32,768 UTF-16 values or glyph indices. The
shared conversion allows 262,144 text units and glyph work items, two million
outline elements and 32 MiB of serialized text paths. Input coordinates, affine
matrices, selected-font glyph counts, generated bounds and font metrics are
checked. These work limits can refuse otherwise valid large Windows inputs.

## Implementation checkpoint

The implementation contains 52 original accepted pictures and 22 refusal
fixtures. All 616 earlier WMF/EMF fixture hashes remain unchanged. Private raw
glyph records derive their indices from the installed Helvetica cmap at runtime,
so the corpus does not assume fixed glyph numbers across macOS font versions.
Independent positions, font metrics and noncommuting matrices distinguish
spacing and orientation errors. The eight new Core methods and native image
consumer group cover these connected behaviors.

The [dated record](qa/metafile-positioned-text-2026-10-20.json) records the passing
universal runtime, both architecture conversions, Debug app build, 21 distinct
relevant Core methods and the grouped native consumers with system and bundled
Git. The initial Core group passed 20 of 21 methods. Its failed cell-height
assertion assumed Helvetica's cell height differed from its em height, while the
actual native metrics were equal. New Arial cell/em controls preserve the strict
geometry assertion; only that affected method was repeated, and passed.

The native group uses 11 representative pictures and two private cmap-derived
raw-glyph records. Actual comparison panes, dropped previews, three-stage image
conflicts, malformed refusal and chooser/cancellation/late-result/grant/Quit
ownership passed with original bytes and repository state preserved. Test windows
were invisible and both receivers were reaped. These linked Debug consumers use
the development helper; separate embedded renderer/source identity checks do not
prove physical UI or distribution-signed execution.

The packaged Debug renderer matches the reconstructed runtime. Its manifest
retains the matching unsigned helper hash beneath ad-hoc signing. No complete
hosted CI, Windows font/raster identity, physical image-window or App Store
acceptance is established by this focused checkpoint.
