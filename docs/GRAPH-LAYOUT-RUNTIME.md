# Revision Graph layout runtime

The standalone Revision Graph uses TortoiseGit's pinned OGDF layout engine.
This is a foundation for the native graph window; building the helper alone
does not establish dialog, menu, Finder or distribution parity.

## Source and algorithms

`Configuration/GraphLayoutRuntime.json` pins OGDF commit
`17f045b131851f5d32af184d5a7a864cec2bfc27`, the gitlink selected by audited
TortoiseGit commit `7338078f8ddd924b8cddee35f512f2286072136d`.
The source archive is checksum verified. OGDF's own COIN sources are built into
the same static runtime, rather than relying on a separately installed solver.
The recursive [source inventory](ogdf-source-inventory.csv) records all 1,866
tracked source blobs and SHA-256 hashes. Every archived file was checked against
its Git blob at the pinned commit; the archive covers the entire tracked tree.
Build/layout contracts were inspected, but individual semantic review of the
other retained third-party files remains pending. This inventory does not mark
every dependency module or the whole application as verified.

The adapter reproduces `CRevisionGraphWnd`'s SugiyamaLayout configuration:
OptimalRanking, MedianHeuristic and FastHierarchyLayout, with layer distance
30 and node distance 25. Native text measurement will determine node sizes.
The helper returns centers and every OGDF bend point, in original node/edge
order. Layout may vary with OGDF's crossing-minimization runs; tests check the
resulting geometry rather than requiring a fixed random arrangement.

Source drawing constructs paths from the source center through the bends to the
target center. It then clips both endpoints to the corresponding rectangle
expanded by half the line width. The native graph renderer must preserve this
clipping, along with source arrow direction, instead of drawing into labels.

## Build and distribution material

The build requires CMake, Xcode's C++ compiler/macOS SDK and Python 3:

```sh
python3 scripts/build-graph-layout-runtime.py
python3 scripts/validate-graph-layout-runtime.py \
  build/graph-layout-runtime/GraphLayout --all-architectures
```

The second command executes both slices; Apple Silicon needs Rosetta for the
Intel slice. Normal validation executes the host slice and inspects both Mach-O
slices, their macOS 13 minimum and system-only dynamic linkage.

The runtime contains the exact OGDF archive, the adapter and reconstruction
scripts/configuration under `Sources/`, plus the original project GPL license,
OGDF's license and GPL texts, and the Eclipse EPL 1.0 text for COIN. OGDF's
original source preserves third-party notices and its explicit COIN linking
exception. The selected source hashes and binary hash are recorded in
`provenance.json` and checked before embedding. The GPL version 2 alternative is
used for this project. Distribution acceptance remains separately outstanding.

The embed script follows existing helper signing: hardened runtime for ordinary
signed builds and inherited sandbox entitlements for AppStore builds. This
implementation is not evidence of signed sandbox or App Store acceptance.
The disposable `scripts/test-graph-layout-embedding.py` checks both ad-hoc
signing branches, provenance updates and preservation of the original runtime.
After inherited signing, the validator checks signatures, entitlements and
metadata; it cannot launch that helper from its unsandboxed Python host. Actual
signed parent invocation remains an explicit native acceptance requirement.

## Protocol and ownership

`TGGRAPH1` carries node count, edge count, positive finite width/height pairs,
then child/parent index pairs. Output repeats the counts, emits each center, then
one bend-count/coordinate record per edge. Repository paths, messages and ref
names do not enter the helper protocol.

Malformed dimensions, invalid indices, self edges, cycles and trailing input
fail before emitting geometry. Input counts above one million nodes or ten
million edges are rejected explicitly; the graph is never silently truncated.
The Swift bridge must own its private temporary files, cancel and reap its own
worker, and reject incomplete or non-finite output. Large layout work must run
away from the UI thread with a usable Cancel action. There must be no unrelated
process termination or background app instances left after testing.

## Verification scope

The runtime verifier checks source/license hashes, architectures, deployment
targets and SDK linkage. Real OGDF fixtures include empty/single graphs,
different-sized diamond nodes, a long edge, an octopus merge and a disconnected
component. It checks preserved counts, finite geometry, non-overlapping node
rectangles, child-to-parent ordering and unchanged input bytes. Malformed and
cyclic graphs must fail.
The built-framework receiver also exercises Debug and AppStore's actual embedded
Core binaries and helper lookup, graph decoding/clipping and a pre-cancelled
request. These console receivers launch no app windows. The ad-hoc embedding
fixture verifies both signature branches without claiming signed native parent
execution.

The current checkpoint's actual test/build and cleanup results are recorded in
`docs/qa/graph-layout-runtime-2026-10-10.json`. Native canvas, overview,
interaction, export and physical/signed acceptance remain separate work tracked
in [Revision Graph parity](REVISION-GRAPH-PARITY.md).
