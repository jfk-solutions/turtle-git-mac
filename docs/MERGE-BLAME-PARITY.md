# Merge Blame comparison keys

This partial workflow review follows pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`, specifically
`TortoiseMerge.cpp` lines 355–358, `DiffData.cpp` lines 196–300 and
`FileTextLines.cpp` lines 265–270, 395–401, 416–422 and 572–582.
The shared Open dialog is `src/Resources/TortoiseMergeENG.rc` / `IDD_OPENDLG`;
this record does not certify that dialog or the editor frame.

The source `/blame` option does **not** create a new author/revision column in
TortoiseMerge. It makes the comparison read-only and removes a fixed metadata
prefix from comparison keys when the source's converted-file path runs.
Earlier port notes incorrectly described a missing Blame-column presentation;
those notes do not represent a pinned source requirement.

`MergeBlameComparison` reproduces the two distinct source decisions:

- `DiffData::Load` converts inputs for case/comment/regex filtering, for UTF-8
  BOM or UTF-16/32, and for CRLF, FF, VT, NEL, LS and PS endings. ASCII/legacy
  inputs also convert when any companion uses a Unicode or converted stream.
  UTF-8 without BOM can bypass conversion, even when a companion converts.
  Plain LF-only ASCII pairs likewise bypass conversion. The native engine
  retains this source asymmetry; using a canonical helper stream does not itself
  enable the Blame projection.
- `CFileTextLines::StripWhiteSpace` removes the first **66 UTF-16 code units**
  only from line payloads longer than 66. Exactly-66 and shorter lines remain
  intact. Comment removal and regex replacement precede this operation; the
  existing whitespace/case comparison follows it. Line endings remain governed
  by the existing comparison option, without changing the displayed input.

`SubversionMergeConfiguration.blame` and `blameEncodings` capture that policy
alongside the comparison options. Native two-file and three-file models supply
the loaded input encodings in Base/Mine/Theirs order. The shared engine applies
each source's conversion decision independently. Its `SubversionDiffPlan` keeps
original line arrays: metadata-only common rows, real code changes, source line
numbers, file bytes, search/copy text and save snapshots continue to use the
original input. The immediate two-file alignment uses the same fixed-prefix
projection while its authoritative engine request is pending.

The launch's Blame state survives File/Open replacement independently of
readonly state. Native editing, transfers, encoding/endings, Save/Save As and
source export retain the immutable no-edit gate; navigation and view switching
remain available. The feature adds no user preference or extra checkbox because
the pinned command is a launch policy.

## Grouped verification

`MergeBlameComparisonTests` covers UTF-16 width/boundaries, every source line
ending, conversion bypass and asymmetric companions, actual two-/three-source
engine segments, original rows, real code changes, comment/regex/case/whitespace
ordering and cancellation. The native
[Blame fixture](qa/merge-blame-native-2026-10-18.swift) covers converted and
unconverted input pairs, case-filter conversion, CRLF, code versus metadata
changes, source line numbering, native read-only text, one-/two-pane switching,
immutable input bytes and ordinary comparison isolation. Parent batch evidence
records actual results after the combined checkpoint; fixture existence is not
a pass.

Physical keyboard/focus, visual light/dark/VoiceOver acceptance and signed
sandbox execution remain separate checks. Existing Windows code-page detection
and macOS decoder differences are not certified by the encoding-conversion mask.
Malformed UTF-16 inside a metadata boundary remains subject to native decoding
and is not an assertion of arbitrary invalid-text equivalence.
