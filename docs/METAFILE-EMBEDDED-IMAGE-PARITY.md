# Embedded metafile images and textures

Pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d` loads metafiles
through Windows GDI+ (`src/Utils/MiscUI/Picture.cpp:399–418`). TurtleGit now decodes
embedded image objects through its existing owned renderer. Comparison, dropped
preview, conflict and Save inputs retain their original encoded bytes.

## Wire and playback contract

[EmfPlusImage](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/02c80141-208e-4335-ad51-190b40a1802c)
contains either a bitmap or a metafile. MS-EMFPLUS 2.1.1.20 and 2.2.2.27 define
five metafile types: WMF (1), placeable WMF (2), EMF (3), EMF+ only (4) and EMF+
dual (5). The declared type and exact size-delimited child bytes are validated
against the actual child header, including EMF+ only/dual flags. Up to three
alignment bytes outside the child are ignored. Invalid lengths, mismatched
headers, malformed records and unsupported child painting fail the complete
outer image; an earlier painted prefix does not become a successful preview.

[DrawImage](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/778bfc49-e058-4fb2-b19d-9f801f8e458a)
and [DrawImagePoints](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/9bad3867-71b0-46fb-9b90-f7d8fb37ff76)
accept the generic image object. Both retain the existing UnitPixel source
contract, destination encodings, source rectangle and parent affine transform.
Child dimensions use the existing intrinsic frame/placeable/window-extent
interpretation. No guessed default dimensions are supplied to an invalid child.

Direct metafile images replay into the live destination with a fresh object
table and graphics state. The child starts in SourceOver; an explicit child mode changes only its
playback. An owned Windows GDI+ reference confirmed that parent SourceCopy does
not make a child default-mode paint replace alpha. Parent clipping and source cropping remain device-space constraints; child
clips cannot escape them. Parent state is restored after playback. In particular,
an explicit child SourceCopy applies to each actual child paint, including
transparent ink, rather
than replacing the entire image rectangle. Unpainted child areas preserve the
parent. Classic destination-dependent ROPs use the real parent destination in this
deterministic native display profile. Windows GDI+ GetDC playback produced an
intermediate-background-dependent color for the authored inversion sample; that
color is not copied or represented as a certified Windows destination rule.
The implementation follows the pinned
[Wine metafile enumeration reference](https://github.com/wine-mirror/wine/blob/7298a818b79446bae153b8d5aa27235ab3703bf9/dlls/gdiplus/metafile.c)
(`METAFILE_PlaybackGetDC` / `GdipEnumerateMetafileSrcRectDestPoints`) and
`graphics.c::GdipDrawImagePointsRect` graphics/container behavior. This is reference
playback evidence, not an independent Windows raster oracle.

## Texture and ImageAttributes consumers

[TextureBrushOptionalData](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/65bf0dda-baf3-4ee0-a6c4-f37a2f73c026)
embeds a generic ImageObject. Microsoft's
[TextureBrush constructor](https://learn.microsoft.com/en-us/previous-versions/ms534546(v=vs.85))
explicitly supports metafiles and scales the entire image to the brush rectangle.
A metafile texture renders lazily on an isolated transparent intrinsic surface,
then enters the existing PNG texture brush pipeline. Transparent child regions
remain transparent. Tile, FlipX, FlipY, FlipXY, Clamp, brush/world transforms,
fill, native pen, native glyph and SourceCopy consumers share that pipeline.
A nested child SourceCopy checkpoint is scoped to its surface and cannot replace
the saved parent checkpoint. Native work counters remain cumulative across scopes.

The serialized [ImageAttributes object](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/9f73a2af-8c9c-4d05-98ab-19a485064364)
contains wrap/clamp information; color matrices are not fields in this wire
object. Direct vector playback validates the attributes object but ignores its
wrap/clamp fields. An owned Windows GDI+ reference rendered all five wrap modes
identically to absent attributes at 256 sampled points with exactly matching
source/destination geometry, including an out-of-natural source rectangle.
Bitmap images retain their separately implemented wrap/clamp behavior. The
[SetWrapMode contract](https://learn.microsoft.com/en-us/windows/win32/api/gdiplusimageattributes/nf-gdiplusimageattributes-imageattributes-setwrapmode)
says its Clamp BOOL has no effect in GDI+ 1.0: both 0 and 1 are accepted as ignored
metadata for bitmap and metafile attributes; other values fail. No serialized
color-matrix, image-effect or undocumented adjustment records are invented.
The same Windows reference painted serialized imageType=Metafile texture
brushes blank. GDI+ accepts a native TextureBrush(Metafile), but its recorder
rasterizes the child into a compressed bitmap image object. Supporting the
specification's generic embedded image in a texture is therefore an explicit
native display extension, not demonstrated serialized Windows pixel parity.
Exact Windows interpolation, fonts and unsampled pixels remain acceptance limits;
independent fixtures establish the bounded native display profile.

## Bounds, ownership and remaining scope

The outer conversion owns all child work. Limits include eight nested child
levels; 4,096 child inspections/replays; 64 MiB per input and 128 MiB cumulative
parsed input; one million cumulative records; and 64 MiB aggregate embedded paint
markup. Existing bitmap,
texture, path, glyph, gradient, mask and pen budgets are shared across children.
Isolated native rasterization allows at most 16,777,216 pixels per child and
67,108,864 cumulative rendered pixels, sharing the existing raster call/markup
limits. Saved native checkpoint buffers are capped at 128 MiB across eight
scopes. Child serialization is bounded to 64 MiB and 131,072 definitions.
Coordinates, dimensions, transforms and final output retain the existing bounds.

The same private helper, captured stdin bytes, cancellation token, process group,
deadline and output limits serve all nested playback. Embedded files cannot
request another executable, load a filesystem reference or access the network.
Rejected children do not publish a partial display or leak graphics state into a
later conversion. The family does not enable otherwise unsupported child
records, effects, arbitrary path-gradient semantics or font substitutions beyond
the existing renderer profile. Classic cosmetic stroke/antialias and text
realization retain the existing display profile; this is not a general Windows
GDI/GDI+ pixel-identity claim.

## Authored fixtures and checkpoint

`generate-embedded.py` writes 57 accepted EMFs, 15 refused EMFs and one literal
PNG control. Existing 1,261 fixture payloads retain their bytes; the previously
refused Clamp BOOL=1 sample is reclassified with the same bytes as
`plus-image-attributes-clamp-ignored.emf`. New controls cover all five child
formats, crop/affine/clip/recursive playback, fresh-child/explicit compositing,
parent-state restoration, full-affine classic glyph/roundrect/clip geometry,
classic destination inversion, transparent child Clear,
isolated checkpoint restoration, and metafile/raw-bitmap texture agreement across
wrap, pen, glyph and SourceCopy consumers.

Nine `MetafileEmbeddedImageTests` methods and cached native
`test-metafile-workflows.py --only embedded-metafiles` are prepared. The native
mode retains malformed-side refusal, original-byte comparison, actual drop/Open,
three-stage Git conflict and cancellation/retirement/Quit ownership checks.
The [dated family checkpoint](qa/metafile-embedded-family-2026-10-24.json) records
18 relevant Core methods, actual helper conversion/refusal on both architectures,
the Debug build and both native Git-engine pairs passing. Both receivers are
independently absent and no metafile helpers remain. The build exited zero with
33 contradictory generic exit-zero compiler diagnostics, retained in its log.
Complete Windows corpus, physical minimum-OS/Intel and signed distribution
acceptance remain separate from these local checks.

The [dated Windows reference](qa/metafile-windows-reference-2026-10-24.json) records
the original synthetic GDI+ runs, exact-geometry attribute comparison and native
texture serialization. These source-reference results establish specific playback
choices; they do not certify the complete Windows rendering corpus.
