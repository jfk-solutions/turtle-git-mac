# Remaining source text-patch adapter workflow

Read-only source audit against `7338078f8ddd924b8cddee35f512f2286072136d`.
This is an explicit implementation gap, not a visual-acceptance count and not
superseded by the PatchSave/AutoAdd policy batch.

`TortoiseMerge/Patch.cpp::ParsePatchFile` (49 onward) consumes decoded
`CFileTextLines` records. It splits ordinary `---`/`+++` file pairs without
requiring `diff --git`, handles SVN revision suffixes and Git quoting, and retains
hunk EOL/BOM information. `CPatch::PatchFile` (425–582) loads the target with its
own decoded text/format settings, applies the hunks, preserves output settings,
and handles a changed UTF-8 BOM. Its context/remove comparisons recognize
expanded keywords through `HasExpandedKeyWords` (584–605): LastChangedDate, Date,
LastChangedRevision, Rev, LastChangedBy, Author, HeadURL, URL and Id.

Current native Review passes original patch bytes to `git apply` for statistics,
validation, simulation and application (`GitPatch.swift::reviewWorkingTreePatch`,
`compareWorkingTreePatchFile`, `withPatchTarget`). The recorded-base recovery
assumes `index old..new` object identities. It does not replace source text-patch
semantics for a plain SVN/GNU patch with no object header. Separately implemented
Unified Diff document codecs preserve/convert raw viewer text but do not decode
or apply Unicode patch containers in this Review pipeline.

Concrete remaining cases include UTF-16/UTF-32 text patch documents, decoded text
patches against UTF-16/UTF-32 targets, expanded-keyword context/removal matching,
and complete multi-file non-Git header/format-state equivalence. A future connected
adapter must retain exact original patch bytes for Copy/Save, use existing path
and scope validation, preserve target encoding/EOL/BOM/no-final-newline, support
Reverse/Strip/per-file selection, and carry simulated results through the existing
stale-input/application/editor policies. It must not normalize or re-encode an
opaque Git binary payload as ordinary text. Its source parser/state rules need
independent authored fixtures and genuine filesystem outputs.

Do not treat a `.rej` viewer as an absent pinned feature: Git/GitPatch.cpp records
an error string with the explicit “we do not support reject files ATM” TODO, and
MainFrm.cpp::PatchFile's rejected-hunk viewer is under `#if 0` (626 onward).
Likewise, native binary/symlink/deletion recovery already has separate implemented
whole-state choices; it must not be reclassified as wholly unimplemented.
