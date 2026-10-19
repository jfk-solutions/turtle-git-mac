# EMF+ formatted text in Image Compare

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
`TortoiseIDiff/MainWindow.cpp:1255` offers WMF/EMF, and
`Utils/MiscUI/Picture.cpp::Load` delegates playback to Windows GDI+.
This family implements formatted `EmfPlusDrawString` in the shared macOS
metafile helper used by comparisons, dropped previews and conflict panes.

## Record and layout contract

The binary parser follows Microsoft's [StringFormat object](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/9df612d2-fb87-44f7-93fb-0fa0b7b2f276),
[variable arrays](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/9567fbcd-d999-4c70-873f-12d320f02dc3)
and [DrawString record](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/ae7927c3-e416-4069-a9b8-3200113d6c41).
Counts are signed where specified, and the complete array extent must match
before any layout begins. UTF-16 must contain complete surrogate pairs and
XML-compatible characters; malformed input is refused rather than replaced.

CoreText shapes the captured text into actual font glyph outlines. The helper
emits vector paths, including fallback run fonts and text matrices, and keeps the
original text/font separately in an SVG description. Descriptions are semantic
metadata, never a second paint or an external font/resource reference. Text
remains vector geometry at arbitrary zoom; existing gradient and texture brushes
retain their documented bounded raster paint clipped to that geometry.

The layout supports explicit paragraphs, wrapping/NoWrap, horizontal alignment,
line alignment, right-to-left reading order, clockwise vertical text, character tracking,
tab stops and first-tab offset, layout clipping/NoClip, whole-line LineLimit,
character/word/ellipsis/path trimming, hotkey prefixes and font decorations.
Vertical output rotates the completed shaped line once, matching the [Microsoft formatting example](https://learn.microsoft.com/en-us/windows/win32/gdiplus/-gdiplus-formatting-text-use); vertical-specific CJK glyph alternates remain unverified.
Tracking changes shaped advances and positions rather than stretching glyphs.
Margins use the recorded em multiplier and the font's converted page-unit size;
this interpretation follows actual recorded values and Wine's default
`font->emSize/6` behavior, rather than the specification's ambiguous inch wording.
Tab distances are page units and cumulative: the first is FirstTabOffset plus
the first interval, as in the [GDI+ GetTabStops example](https://learn.microsoft.com/en-us/windows/win32/api/gdiplusstringformat/nf-gdiplusstringformat-stringformat-gettabstops).

[Microsoft's managed StringFormatFlags](https://learn.microsoft.com/dotnet/api/system.drawing.stringformatflags)
defines bit 0x400 as disabling fallback. Its meaning contradicts the prose in
MS-EMFPLUS and parts of the native API page; the implementation uses the managed
GDI+ meaning and the requested font's missing-glyph outline when fallback is
disabled. The [native HotkeyPrefix enumeration](https://learn.microsoft.com/en-us/windows/win32/api/gdiplusenums/ne-gdiplusenums-hotkeyprefix)
controls literal ampersands, hidden markers and visible underlines. Font underline
and strikeout use actual font metrics, not guessed line positions. A strikeout
font without usable OS/2 metrics is refused.

Digit substitution None (1) is literal. User (0) is implementation-defined in the
[enumeration](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/dcc3e25a-6d9c-4e3e-ac04-dd34203d1cc1);
this renderer chooses deterministic unchanged digits for neutral DigitLanguage.
Explicit national/traditional substitution and non-neutral DigitLanguage remain
refusals. Measured-character ranges are fully bounded metadata and do not alter DrawString
paint; this does not add a MeasureCharacterRanges API. DisplayFormatControl remains
explicitly unsupported. Glyph-ID `DrawDriverString` is a separate remaining
painting family, not silently treated as Unicode DrawString.

Beyond the explicit tab list, this native implementation repeats the final
interval with its initial phase preserved. Without explicit stops it uses eight
actual shaped space advances. These are bounded native continuation/default
policies. Microsoft's documentation specifies cumulative explicit stops but not
what follows the last one, and Wine's text layout still has a tab-stop FIXME;
exact Windows continuation remains unverified. This distinction is retained in
the fixtures rather than presented as certified GDI+ behavior.

Non-neutral text Language identifiers are converted from Windows LCIDs to native
CoreText language attributes. Unknown mappings fail explicitly; neutral Language
uses native font shaping defaults. This is separate from numeric DigitLanguage.

## Bounds, ownership and remaining acceptance

Each DrawString is limited to 32,768 UTF-16 units and 256 explicit tab intervals.
A conversion has separate 262,144 input-text-unit and shaped-glyph-work budgets, two million outline
elements and 32 MiB of serialized text paths. Layout coordinates, margins,
tracking, font sizes, line counts and output bounds are validated. Repeated
shaping for trimming also charges the work budget. Complex or extreme text can
therefore fail explicitly within a parent-owned deadline; those limits are not a
claim to accept every otherwise valid GDI+ record.

Zero-size rectangle extents are treated as point-layout anchors for alignment,
not as a reason to ignore Center/Far. Oversized blocks retain negative centered
offsets rather than silently becoming top-aligned, following Wine
`gdip_format_string` and `GdipDrawString`. The fitting limit can be unbounded while
the alignment extent remains zero. Exact Windows glyph metrics remain separate.

No document path, font file, module loader, network or executable API is exposed
to JavaScript. The owning image operation still cancels and drains its exact
helper, and rendering preserves original input/conflict bytes. Color/bitmap-only
glyphs without vector outlines are refused; Windows-only fonts can differ or
substitute through CoreText. Pixel-identical Windows font metrics, all LCID/font
variants, vertical CJK typography, physical Image Compare acceptance and signed
App Store distribution remain unproven.

The synthetic corpus generator supplies independent records and final-pixel
assertions for layout, clockwise vertical orientation, brush paint and clipping,
plus malformed framing and resource limits. [Batch evidence](qa/metafile-text-2026-10-19.json)
records actual checks and failed attempts. A focused pass does not certify all
metafile drawing or whole-application parity.


The final universal helper and Debug app builds passed. The grouped Core result
covers 38 distinct methods across the original group and focused repairs; only
the affected six, then two, then one methods were repeated after actual failures
or a source-proven alignment correction. Both architectures executed actual
baseline/RTL/vertical/point text conversions and malformed UTF-16 refusal. The
native consumer family passed with system and packaged Git, including six new
formatted-text files and the retained corpus, chooser, previews, conflict and
ownership paths. Receivers remained invisible and were reaped; original bytes
were preserved. The new source/archive/patch provenance matches the packaged
runtime. These scoped results do not establish a full hosted integration pass,
all Windows font behavior or signed App Store acceptance of this text subset.
