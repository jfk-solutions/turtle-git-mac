# Classic path native API witness

These original Windows GDI programs produced18 eligibility observations and14
full GetPath device-geometry observations on2026-11-23. The inputs are finite
ordinary/geometric/cosmetic/stock/null pen and mapping cases. No renderer output
or pixel oracle is used. The capture did not open GUI applications or alter VM
configuration.

The original C++ sources, stdout observations, compiler output and runtime
version bytes are retained. `manifest.json` records original executable/source/
runtime hashes and exported file hashes. Exported receipts omit ephemeral paths;
the original private receipts remain in build evidence.

`Eligibility.cpp` records API outcomes and logical GetPath bounds.
`EligibilityGeometry.cpp` records complete GetPath vertices after selecting an
identity world mapping, exposing captured device geometry. Compile with the
manifest's Visual C++ command and run each program synchronously to stdout in a
private directory. The programs own and release their memory DC/pen resources.

Current Windows accepted ordinary thin/zero, stock and null pen widening in the
captured cases; ExtCreatePen cosmetic widening failed. This is narrower evidence
than general Windows raster equivalence: integer outlining, cap quantization
and other unrecorded device profiles remain unverified.
