# Hand-serialized DIB V4/V5 framing inputs

`../generate-dib-profiles.py` writes only this directory. Regenerate with its
retained `profiles/` input copies; first generation may explicitly supply
`--profile-directory` for the original profile-generator directory.

The 86 inputs cover EMF and WMF raster, direct-scanline and DIB brush consumers.
Every scene is 64×64 and carries a literal asymmetric 4×4 top-down BGR24 source.
A white background and earlier red sentinel make dropped whole-file/error
handling distinguishable from a valid empty scene. No renderer was used to
serialize these wires or compute expected output pixels.

`manifest.json` lists exact file bytes/SHA256, consumer/family/container,
placement, structural framing classification, source pixel bytes, ICC input
hashes, BMI/bit/profile offsets and sizes, and recorded ICM operations. Valid
profiles in separate EMF spans precede the bits within BMI or follow the bit span;
the declared profile offset is always relative to the DIB header. Separate EMF after-bits records keep
`cbBmiSrc` header-only and `cbBitsSrc` pixel-only. Packed WMF has no separate
pixel offset: pixels begin immediately after the header/table. Its valid embedded
profile follows the bits. The six deliberately packed profile-before-bits WMFs
therefore overlap the actual implicit pixel span and are classified malformed,
even though Windows may paint the profile prefix as garbage pixels. Their
manifest distinguishes implicit pixel offsets/hashes from the physically stored
intended source-pixel offset. The implicit pixel address is never rebased around
the profile.

The four malformed variants deliberately overlap pixels, point inside the DIB
header, overflow the record address space, or truncate the declared profile.
These are structural discriminator classifications, not claims about native
Windows tolerance or display colors. sRGB profile-offset/gamma/endpoints metadata
is explicitly inactive. Six additional EMF cases record ICM QUERY (3),
DONE_OUTSIDE_DC (4), or SaveDC/RestoreDC state sequences; the manifest records
operations without assigning an output color policy.

The two ICC files are original matrix/TRC profiles authored by
`docs/qa/metafile-dib-profile-reference-2026-10-29/generate-profiles.py` in the
independent Windows reference source. No vendor/device profile bytes are used.
The display interpretation of every active profile remains subject to that
native capture and the actual consumer contract; input ICC validity alone does
not prove a particular metafile consumer performs color conversion.
