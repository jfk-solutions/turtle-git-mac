# Compact and batched classic metafile text

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
Its image viewer uses GDI+ to load Windows metafiles. This continuation connects
additional classic EMF text records to the existing native outlined-text engine
used by comparison, previews and image conflicts. The original file remains the
repository/save input; decoded outlines are private display data.

## Record contracts

Microsoft's [SmallTextOut record](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/20eee81d-0bd4-42d1-a624-860adfe62358)
stores compact text using either UTF-16 or low Unicode bytes. The
[output options](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/e7ffcc53-40d1-4873-8eda-c5c5ee104aa5)
make `ETO_SMALL_CHARS` select the low-byte form; those bytes are not an ANSI
code page. `ETO_NO_RECT` removes the optional bounds field. The old renderer
reversed the width choice and bypassed the shared classic text implementation.

[PolyTextOutA](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/d8b7ac21-76b8-4f9a-a7cc-05f9d2d5627e)
and its wide counterpart batch text operations in one record. Each
[EmrText descriptor](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/dd585d0a-5d7c-4034-963a-1141af836972)
provides its own origin, options, string offset and optional spacing offset.
Offsets belong to the containing record. Batched playback must retain operation
order and each string's clipping/background behavior. The earlier adapter
refused these record types entirely.

## Connected execution

The implementation shares the positioned classic text painter instead of using
an independent approximate SVG text path. Selected font metrics, graphics mode,
world mapping, explicit advances, alignment and current-position continuation
remain governed by the [positioned text contract](METAFILE-POSITIONED-TEXT-PARITY.md).
Background, clipping, empty strings and saved drawing state are part of each
operation. ANSI ExtTextOut and PolyTextOut use the selected LOGFONT charset;
multibyte source bytes and their displacement entries must map to the same
Unicode character before font placement.

Whole record descriptors, string and displacement extents are validated before
batch painting. Existing per-call and conversion-wide text/glyph/outline budgets
apply across the batch and following records. Malformed or unsupported semantics
fail the conversion rather than yielding a successful partial picture.

## Windows reference and remaining boundaries

The [independent Windows reference](qa/metafile-classic-text-windows-2026-10-26.json)
records 84 initial cases and eight focused follow-ups through PlayEnhMetaFile,
per-record GDI enumeration and GDI+ DrawImage. Separate engine/control comparisons
confirm the compact widths, low Unicode bytes, compressed glyph indices and
byte-oriented Shift-JIS displacement sums. The original source inputs, actual
statuses, artifact checksums and corrected control assumptions remain recorded.
These comparisons do not establish macOS/Windows pixel identity.

For SmallTextOut, absent bounds make explicit clipping/opaque flags ineffective;
normal background mode still belongs to the shared painter. PolyTextOut uses
fixed forty-byte descriptors. The tested omitted-rectangle variants fail Windows
record playback; the adapter refuses them. Windows also treats a zero PolyTextOut
spacing offset as a pointer to the record header rather than natural advances.
The adapter reproduces the measured header spacing using only available bytes.
It refuses an array that would read beyond the record. ANSI ExtTextOut without a
spacing array retains its ordinary native-advance behavior.

Explicit ANSI charsets cover Windows 1250–1258, 874, 932, 936, 949 and 950.
Unknown/default/OEM high bytes and Symbol font-specific ANSI mapping remain
refusals; ASCII does not require guessing a system code page. ANSI glyph-index
input is refused, while compact UTF16 and compressed low-byte glyph indices use
the selected installed font's cmap IDs. Existing locale/numeric/RTL option,
opaque path-text, font substitution and exact GDI rasterization boundaries remain
in the positioned-text contract. This is additional connected record support,
not certification of all Windows metafiles.

The [grouped local checkpoint](qa/metafile-classic-text-records-2026-10-26.json)
records fourteen distinct relevant Core methods passing cumulatively, the
universal helper build/reconstruction and selected conversions in both slices,
a Debug app with matching packaged source identity, and the dedicated native
workflow passing with both Git engines. All 1,626 earlier binary fixtures remain
unchanged. One new path fixture selected a black pen instead of a black fill
brush; only the two methods affected by the corrected subject/control files were
repeated. Native checks cover seventeen samples, fourteen equivalence pairs and
forty refusals per engine, actual image conflicts and cancellation/retirement,
with both receivers absent. Existing native compiler warnings remain in the log.

The native case is included in hosted CI, but a complete hosted result is not
claimed. Physical image-window, current signed installed, minimum-version and
physical Intel acceptance remain separate; x86_64 helper execution used Rosetta
on the current arm64 host.
