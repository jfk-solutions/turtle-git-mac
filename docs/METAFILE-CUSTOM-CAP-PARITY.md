# EMF+ custom line caps

This batch extends the existing EMF+ pen playback used by native image comparison.
TortoiseIDiff uses Windows GDI+ for these images. TurtleGit constructs bounded
native outlines from captured metafile records, then paints those outlines with
the existing solid, gradient, hatch or texture brush. Original repository image
bytes remain unchanged.

## Source and binary contract

Microsoft specifies the complete versioned [custom cap object](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/67d95a39-7b04-47e8-bc12-52d60596457a),
[default cap data](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/6fbd47ae-6c34-424c-b4cc-0e86e78d9bd4),
[adjustable arrow data](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/f4c454d8-775b-4379-a0c7-bf7e64ca3480)
and [optional path order](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/967095e9-c2cf-4b25-936a-57136754baec).
Pen custom-start and custom-end fields each carry their own size followed by a
complete cap object, before the complete embedded brush. A standalone ObjectType9
cap is validated and stored; embedded pen caps contain data rather than an ID
reference to that object.

Default cap fill and outline paths each have a signed byte length and a complete
versioned Path. Path coordinates remain in cap-local units until native outline
construction. Floating, compressed-short and relative coordinates retain their
wire meanings. The specified Path R flag couples relative points and type RLE,
with the C flag ignored. RLE runs retain the required marker and Bezier bit; an
independent undocumented RLE flag is not inferred from the base renderer. Counts, point kinds, cubic sequences, run lengths, independent
path extents and final alignment padding are checked before geometry is used.
Padding has no drawing meaning and need not be zero. Fill and stroke hotspots
are unused playback metadata and are ignored, including nonzero bit patterns. Unknown type/style/flag values, nonfinite metrics, nested truncation,
invalid lengths and exhausted geometry budgets produce an explicit unsupported
image diagnostic.

The [GDI+ CustomLineCap constructor](https://learn.microsoft.com/en-us/windows/win32/api/gdiplusheaders/nf-gdiplusheaders-customlinecap-customlinecap(constgraphicspath_constgraphicspath_linecap_real))
defines two important playback rules: an outline path takes precedence when both
paths are present, and custom cap fill uses winding regardless of the Path fill
mode. The paths are still independently validated, including an unused fill path.
The same rule prevents a malformed inactive pen attribute from bypassing validation.

[AdjustableArrowCap MiddleInset](https://learn.microsoft.com/en-us/windows/win32/api/gdipluslinecaps/nf-gdipluslinecaps-adjustablearrowcap-setmiddleinset)
moves the base midpoint: positive values form a notch, negative values form a
diamond, and an inset at least as high as a filled arrow makes that cap invisible.
It has no effect on an unfilled arrow. WidthScale acts relative to the physical
pen width; cap-local +Y points outward along the endpoint tangent. Default cap
body trimming uses pen width multiplied by BaseInset, independently of the cap
geometry scale. Adjustable arrows retain the intrinsic triangular base cap and
height/width inset observed in Wine
[native compatibility tests](https://github.com/wine-mirror/wine/blob/7298a818b79446bae153b8d5aa27235ab3703bf9/dlls/gdiplus/tests/customlinecap.c),
as model metadata. The painting reference uses a flat trimmed shaft rather than
adding an independently inferred triangular shaft adornment. These metric
policies still require Windows pixel certification, especially WidthScale and
BaseInset interactions; they are not inferred from matching a generated SVG.

## Connected implementation

The reconstruction patch's `turtleGitPens.js` validates and retains complete
custom cap objects. It sends generated cap-local paths and finite style metadata
to `NativeStrokeGeometry`, alongside the captured shaft pen, linear nib transform
and world transform. Custom cap enum255 requires its corresponding embedded data;
stored inactive custom attributes are validated without becoming active caps.
The native bridge owns cap construction, body trimming, winding outlines, boolean
union, actual paint bounds and aggregate geometry budgets. Binary cap objects
are bounded to eight MiB, each path to 65,536 points and generated cap-local SVG
to two MiB; the existing conversion-wide input and outline budgets still apply.

Custom adornments belong to physical open endpoints. Compound bands do not
multiply the cap, and dash gaps use dash caps rather than custom endpoint caps.
Closed figures suppress custom endpoint caps. Multi-figure paths retain their
own physical starts and ends. Pen translation remains ignored while its linear
transform, captured page/world transform and captured clipping apply once.
Actual union bounds feed the existing brush pipeline, so a cap can extend the
paint area beyond the shaft without changing its brush or leaking that brush to
a later stroke.

## Verification scope

The generator source contains independent complete binary objects for default
fill/outline precedence, winding subpaths, local stroke styles, BaseInset and
WidthScale, adjustable arrows, relative/short/RLE paths, both endpoints,
multi-figure/closed paths, compound/dashed shafts, brush families, transforms and
captured clipping. Refusal fixtures isolate malformed nested framing and style
fields inside otherwise valid outer record chains. Analytic pixel regions and
ordinary shape controls are used as geometry oracles; serializing the generated
SVG a second time is not a pixel oracle.

The universal helper build, both-architecture reconstruction/deployment check and
Debug application build passed. The relevant Core group ran 55 methods: 54 passed
initially; one antialias-boundary sample was corrected using independent analytic
geometry and its affected method passed. Production geometry and strong channel
assertions were retained; the full group was not repeated for that sample repair.

The native consumer group passed with system and bundled Git, each covering 45
representative images, including six new custom-cap samples. It retains actual
IDiff/Merge routing, original bytes, preview/reload, conflict decoding and owned
cancellation/late-result/grant/Quit checks. Both hidden receiver processes were
reaped and independently absent. Prepared, packaged and current helper source
identities match. The receiver uses the development-helper fallback, so this does
not prove signed-parent invocation. [Batch evidence](qa/metafile-custom-cap-2026-10-19.json)
records the initial sample failure, focused repair, exact scope and remaining
Windows, hosted, physical and signed acceptance limits.

## Explicit remaining limits

Wire PenAlignment Left2, Outset3 and Right4 remain refused. Although the
[file format enumeration](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/22cd03cb-3602-4f0c-b5ef-777348a7ddf6)
assigns them values, the [public native GDI+ API](https://learn.microsoft.com/en-us/windows/win32/api/gdiplusenums/ne-gdiplusenums-penalignment)
documents Center and Inset. An actual Windows playback oracle is required before
claiming behavior for the additional wire values. Wine's alignment storage does
not establish playback support. Existing disallowed inset/compound and
inset/triangular-dash combinations retain their explicit refusals.

Windows pixel captures remain necessary for complete cross-platform cap
certification, particularly implementation-defined or undefined geometry such as
BaseInset beyond the available line length. Such geometry must not silently turn
into a guessed ordinary cap. The user-linked layout2vector writer and
BaseHmiTypes renderer do not currently supply custom-cap playback or Windows
pixel references; their existing uses and retained notices are unchanged.

The [WidthScale API](https://learn.microsoft.com/en-us/windows/win32/api/gdiplusheaders/nf-gdiplusheaders-customlinecap-setwidthscale)
and its examples define uniform cap-geometry scaling relative to physical pen
width. This implementation separates that geometry scale from shaft trim:
BaseInset is multiplied by pen width, without multiplying by WidthScale. The
[BaseInset API](https://learn.microsoft.com/en-us/windows/win32/api/gdiplusheaders/nf-gdiplusheaders-customlinecap-getbaseinset)
describes separation but does not explicitly settle their coupling; the separate
trim follows the available rendering reference and still needs Windows pixels.

Adjustable-arrow metadata retains its intrinsic Triangle base-cap property.
The custom-arrow painter uses a flat trimmed shaft and draws the arrow's own
geometry, following the reference painting branch. Getter tests alone do not
prove an additional triangular shaft adornment. Invisible/zero/outlined arrow
shaft metrics remain part of the explicit Windows-oracle boundary; analytic
fixtures must not be described as Windows-certified pixels.
