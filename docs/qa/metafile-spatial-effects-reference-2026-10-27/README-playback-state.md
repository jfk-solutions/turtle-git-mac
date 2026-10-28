# Bounded native playback state and Blur source-region discriminator

This assay records pending native evidence; it does not modify existing oracles
or establish a process-history explanation in advance.

`redeye-playback-state-inputs.json` contains three unchanged synthetic EMF wires
already present in the retained corpus, with exact byte counts and SHA256:

* `followup-solid-pure-red.emf`: opaque pure-red255 residual.
* `detector-color-pure-red.emf`: independent opaque pure-red255 residual.
* `redeye-17.emf`: accepted immutable/disjoint-area and highlight-carry control.

`RedEyePlaybackStateReference.cpp` only opens files through `Bitmap(path,FALSE)`
under GDI+ startup1 and draws into a native ARGB bitmap using Picture's SourceCopy, default interpolation, half pixel offset and
TileFlipXY settings. The actual consumer anchors are pinned TortoiseGit
`src/Utils/MiscUI/Picture.h:197` and `Picture.cpp:415`. No direct/created effect
calls or image generators run in these processes. Only width/height queries
precede the consumer draw. Final output and intrinsic RGBA/PNG observations happen
after it, so PNG encoding or GetPixel cannot force decoding before Picture
first consumes the file.

Each retained wire is played in three fresh processes (nine playbacks). Forward
and reverse orders each run in one further process (six playbacks). Old references
are preserved separately; a difference must be reported with its exact input,
stage, order and full-buffer hashes before attributing it to history.

The same workflow compiles `BlurSourceRoiContractReference.cpp` to record four
precisely bounded source-region questions and one contained control. These use
the existing opaque asymmetric source, radius2/ExpandEdge, SourceCopy and a prior
opaque sentinel. Each is replayed in its own startup1 Picture process. Out-of-
bounds recording draw statuses are observed; setup and contained-control statuses
must succeed. Requested and observed source bytes must match exactly.

The combined inventory is 16 playback processes, 20 file playbacks, 40 full RGBA
buffers and 40 PNGs. The five Blur recordings use their own startup2 recorder;
they do not precede any RedEye direct effects inside a playback process. Source,
materialized inputs, toolchain, executable, GDI+ module version, OS, manifests and
all output member hashes are retained. The workflow checks each declared geometry,
name, status, RGBA byte count and source equality before uploading.

Native observation is pending. The workflow may be dispatched or triggered by an
approved source push; authoring these files does not itself run the capture.
