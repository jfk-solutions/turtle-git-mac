# Source text-patch adapter implementation and remaining acceptance

Read-only source audit against `7338078f8ddd924b8cddee35f512f2286072136d`.
The connected Unicode/SVN/keyword adapter follows the PatchSave/AutoAdd policy
batch and has a separate grouped checkpoint record. This record separates the former missing
workflow from implementation and unverified acceptance; it is not a feature
completion percentage.

`TortoiseMerge/Patch.cpp::ParsePatchFile` (49 onward) consumes decoded
`CFileTextLines` records. It splits ordinary `---`/`+++` file pairs without
requiring `diff --git`, handles SVN revision suffixes and Git quoting, and retains
hunk EOL/BOM information. `CPatch::PatchFile` (425–582) loads the target with its
own decoded text/format settings, applies the hunks, preserves output settings,
and handles a changed UTF-8 BOM. Its context/remove comparisons recognize
expanded keywords through `HasExpandedKeyWords` (584–605): LastChangedDate, Date,
LastChangedRevision, Rev, LastChangedBy, Author, HeadURL, URL and Id.

Before this batch, Review passed original patch bytes to `git apply` for
statistics, validation, simulation and application. Unified Diff codecs could
preserve/convert viewer text, but did not supply source decoded patch application.
The new immutable `SourceTextPatch` parser and `SourceTextPatchApplication`
simulator supply that separate format/matching receipt. Target matching and
`GitPatch.swift` integrate it into the existing selected/all review, comparison,
recorded-base recovery and checked publication workflow. Normal Git, binary and
special-file routes must retain their existing behavior.

Implemented/parser and simulation scope includes UTF-16/UTF-32 patch containers
and targets, captured legacy decoding, multi-file GNU/SVN headers,
expanded-keyword context/removal matching, bounded source cursor lookahead,
Reverse/Strip, original bytes, and BOM/record-ending state. Regular mode and
rename/copy metadata are explicit receipts, not permission to drop those changes.
Source warnings do not change the preceding newline; missing and zero-byte/BOM-only
preimages have distinct source record states. Quoted native Git filename bytes
are preserved before SVN annotation handling. Exact rules and adaptations are
documented in [Unicode and source text patches](SOURCE-TEXT-PATCH-PARITY.md).

The [dated grouped record](qa/source-text-patch-family-2026-10-23.json) reports
actual checks, failures and unrun cases after implementation freezes. Required
acceptance includes actual filesystem output and index behavior for selected/all,
new/deleted/moved/copied/executable files, clean recorded-base recovery, target
codec/ending/BOM states, original-byte Copy/Save, strict mixed/opaque refusal,
stale/path/permission refusal, captured preferences, cancellation and retired
native owners. Authored fixture files and this guide do not establish a pass; the dated record
provides the actual validation scope.

Explicit future boundaries remain: no invented base for a plain SVN revision,
no arbitrary backward/fuzzy search, no binary payload transcoding, and no partial
application of a mixed document whose unsupported records would be lost.
Metadata-only Git changes remain on the Git route. External patch producer
variants outside the pinned source grammar require concrete examples and
independent fixtures before an acceptance claim.

Do not treat a `.rej` viewer as an absent pinned feature: Git/GitPatch.cpp records
an error string with the explicit “we do not support reject files ATM” TODO, and
MainFrm.cpp::PatchFile's rejected-hunk viewer is under `#if 0` (626 onward).
Likewise, native binary/symlink/deletion recovery already has separate implemented
whole-state choices; it must not be reclassified as wholly unimplemented.

Extended reverse-copy metadata stays on the original Git route. A decoded Unicode
container that Git cannot read does not gain invented reverse-copy semantics.
The pinned CPatch path does not define such a reverse-copy operation; this
additional native format combination remains unsupported and explicitly separate
from ordinary Git reverse-copy support.
