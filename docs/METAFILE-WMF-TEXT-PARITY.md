# WMF text, fonts and saved drawing state

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
Its image viewer loads WMF through GDI+ (`Utils/MiscUI/Picture.cpp::Load`).
This family replaces the older WMF SVG-text approximation with the native
outlined painter already used by classic EMF text. Repository, comparison,
conflict and Save inputs retain their original bytes.

## Wire and font contract

Microsoft's [TextOut record](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-wmf/96531e1a-1875-49e5-b797-b4c4c50fa789)
puts its coordinates after the byte string and WORD padding. An odd byte count
cannot move the coordinate fields one byte earlier. The
[ExtTextOut record](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-wmf/7d07c44a-a828-4b82-9af0-e0a81cced5a8)
adds an optional rectangle and signed WORD displacements. Text decoding belongs
to the selected font's charset, independently of whether a displacement happens
to be zero. Clipping and opaque background output are part of the same operation.

The selected LOGFONT retains its original signed height, average width,
escapement, orientation, charset, weight and decorations. This matters when a
cell height and an em height differ, or when text is rotated. The shared
[positioned-text contract](METAFILE-POSITIONED-TEXT-PARITY.md) supplies native
font outlines and mapping rules; it does not certify Windows font-mapper or
pixel identity. Explicit charsets use bounded native decoding, including OEM437
and Johab1361. Johab uses strict in-process system libiconv because the advertised
Core Foundation codec rejected valid Windows samples on the measured host. No
external codec process is launched. Missing Unicode glyphs request a bounded native fallback font,
retaining that glyph's font for advances and outline extraction. Repeated scalar
lookups are cached. Primary font cell/background and average-width semantics
remain separate. Raw glyph indices still require the exact installed font;
missing or bitmap-only outlines are refused.

## Text state and spacing

Alignment applies to the complete string. UPDATECP uses the saved current
position and must retain the source's left, right and center continuation rules;
per-character centering or an unconditional positive x advance would change the
next operation. SaveDC/RestoreDC retains the selected font, alignment, charset,
text/background colors and related spacing state. Object-table lifetime remains
separate from the saved selection.

WMF character-extra and break-justification records affect natural text spacing.
Microsoft's [SetTextJustification contract](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-settextjustification)
describes the font's break character and a running rounding term between runs.
The implementation must distinguish natural and explicit displacements, preserve
negative values and transformed units where supported, and reset or restore the
state at the appropriate source operation. The [independent Windows reference](qa/metafile-wmf-text-windows-2026-10-26.json)
records four runs, including direct APIs, real WMF recording, record replay and
GDI+ playback. Negative character extra applies to natural characters only while
the resulting advance stays positive; otherwise the original advance remains.
Explicit DX always receives signed character extra and ignores break
justification. The observed natural justification uses a sixteenth-unit quotient
and fractional current-position carry, with negative break advances clamped to
zero. That fixed-point explanation is an inference from sampled endpoints,
not inspection of Windows internals.

For the four conventional DBCS charsets, byte advances combine per decoded
character. Measured Johab uses the first decoded-character-count entries instead.
WMF PDY requires twice the ordinary displacement payload, yet playback treats
its first character-count WORDs as horizontal advances; it is not EMF's paired
horizontal/vertical operation. Truncated forms refuse. High-bit WMF stock
selectors are invalid and leave the previous selection; real native recording
materializes stock fonts and pens as ordinary objects and selects real slots.

## Embedded playback and ownership

WMF text shares the existing child-metafile transform and clipping boundary.
It must not apply a parent matrix once through coordinate mapping and again
through a legacy local-paint wrapper. Child state remains independent; text and
glyph/outline work still reserve from the complete conversion's shared budgets.
Malformed lengths, partial arrays, unsupported semantics or unavailable mappings
fail the whole conversion, including any earlier painted prefix. The existing
image-loader operation owns helper cancellation, process drain and private files.

## Implementation and validation boundary

The [dated record](qa/metafile-wmf-text-2026-10-26.json) records 26 distinct
relevant Core methods passing cumulatively across the actual repairs, universal
helper reconstruction and conversion/refusal on both architectures, the Debug app
build and both native Git-engine workflow pairs. The two failed Core methods
were rechecked after strict Johab decoding and the independent expected raster
coordinate repair; the complete Core suite was not rerun. Both owned native
receivers were reaped and independently absent. All 1,810 older binary fixtures
retain their bytes. Windows control equality is specific
to each engine: GDI+ WMF and EMF can rasterize differently. No full cross-platform
pixel identity follows from equivalent logical records.

Glyph-index WMF string semantics, Symbol-specific ANSI mappings, RTL/numeric
options and the full Windows font mapper remain outside this batch. Native font
linking improves represented Unicode text; it does not add complex-script
paragraph shaping or support bitmap/color-only glyphs. Physical image-window,
current signed-installed, minimum-macOS, physical Intel and complete hosted
acceptance remain separate.
