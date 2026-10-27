# Native Windows image-effects reference

This standalone assay uses Windows GDI+ version 2 and the SDK effect classes. It is an early reference-only check for two implementation blockers: the brightness/contrast channel table and serialized effect lifetime. It does not build or test TurtleGit.

The manual `metafile-image-effects-reference.yml` workflow compiles with MSVC on Windows 2022. It saves original native `state-seed.emf`, five strictly framed state variants, straight top-left RGBA, PNGs, JSON API statuses, effect auxiliary LUT bytes, record listings and SHA256 receipts. No Wine output is accepted as Windows evidence.

The 256×4 direct source contains a grayscale ramp, independent RGB ramps, an alpha ramp and zero-alpha RGB. All 81 combinations of brightness {-255,-128,-30,-1,0,1,30,128,255} and contrast {-100,-75,-25,-1,0,1,25,75,100} are applied to every input level. The SDK auxiliary 1024-byte B/G/R/A tables are preserved when available. Matrix and LUT effects separately distinguish channel order, alpha and bias.

The 256×64 recorded seed uses SourceCopy, effect A, plain draw, Save/effect B/Restore/effect A, BeginContainer/effect B/EndContainer/effect A, image attributes and a clipped final draw. Rows start at y=0,8,16,24,32,40,48,56. The generator retains native image/attribute objects and native draw payloads while changing only serialized-effect presence and E flags. Variants distinguish repeated consumption, non-E draws, graphics-stack lifetime, missing effect and most-recent effect. Record indices/flags remain available to check what the recorder actually emitted. A recording or load failure remains an explicit failed/unsupported observation, never evidence of pixel equality.

Playback deliberately uses `Bitmap(path,FALSE)` then DrawImage, matching pinned TortoiseIDiff Picture's constructor path. Compare direct and replay outputs independently; no equality or formula is presumed. RGBA is straight from GetPixel; fully transparent RGB can be lost by native storage and must not be inferred from the input.

Primary references: [Graphics::DrawImage effect overload](https://learn.microsoft.com/en-us/windows/win32/api/gdiplusgraphics/nf-gdiplusgraphics-graphics-drawimage%28image_rectf_matrix_effect_imageattributes_unit%29), [Effect auxiliary LUT](https://learn.microsoft.com/en-us/windows/win32/api/gdipluseffects/nf-gdipluseffects-effect-getauxdata), [EMF+ SerializableObject](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/bbd49011-1527-46be-8fe6-ccceecfd005f).
