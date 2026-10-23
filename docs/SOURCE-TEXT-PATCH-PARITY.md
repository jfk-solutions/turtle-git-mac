# Unicode and source text patches

Source pin: `7338078f8ddd924b8cddee35f512f2286072136d`.
The connected adapter batch covers decoded patch headers and hunks, target-folder
matching, Review Patch file selection, Before/After comparison, recorded-base
recovery, and checked application through the existing patch editor/save policies.
It supplements the Git patch engine; it does not replace Git's binary or
special-file handling. The [dated grouped record](qa/source-text-patch-family-2026-10-23.json) reports
actual validation scope and failures. Authored fixtures are not passing evidence.

## Review and original data

The immutable `SourceTextPatch` receipt keeps the original bytes, decoded text,
captured container encoding, file order, exact path bytes, hunks and line-format
state. Copy and unedited Save retain the original patch bytes. Decoding a UTF-16
or UTF-32 patch for Review does not convert the patch file on disk or force that
encoding on the files being patched. The captured Merge UTF-8/legacy-code-page
policy governs detection, independently of later Settings changes.

Ordinary GNU/SVN `---` and `+++` file pairs do not require a `diff --git` header.
SVN revision annotations, tab-delimited timestamps and fullwidth revision
parentheses are handled. Only an `index old..new` record supplies recorded Git
object identities; a numeric SVN revision is not a Git blob identifier. An
arbitrary SVN patch without a recorded Git base cannot acquire invented
three-way recovery.

Source default paths remove `a/` and `b/`; an explicit Strip count operates on
the retained raw header paths. Reverse swaps before/after paths, ranges, line
roles, BOM flags and recorded identities while retaining the original document.
Native quoted Git names preserve literal parentheses, escaped backslashes,
octal filename bytes and Unicode composition. Parsing these quoted tokens before
SVN annotation trimming is an intentional macOS adaptation: valid Git filenames
must not be truncated or changed into different filesystem paths. Unquoted
source Windows-style separators remain supported.

Regular executable modes and rename/copy roles are retained in the per-file
receipt. They must pass through the checked multi-path application writer; text
simulation alone does not authorize dropping metadata or overwriting a rename
destination. Metadata-only Git changes stay with Git. Extended reverse-copy metadata also
stays on the original Git route; Unicode containers that Git cannot decode do
not acquire invented reverse-copy semantics from this adapter. Mixed documents containing
an unsupported opaque record are refused by the text adapter as a whole, rather
than applying only their text subset.

## Matching follows the pinned patch algorithm

`TortoiseMerge/Patch.cpp::ParsePatchFile` (49–372) and `PatchFile` (425–582)
define this compatibility behavior. Hunk counts must match before a complete
receipt is returned. Unknown markers, incomplete headers, count overflow and
unterminated hunks fail without publishing a partially parsed selection. Parsing
and simulation are bounded and cancellable.

Removed lines compare exactly at the current new-line cursor and remove that
line without advancing the cursor. Context compares the current new and old
cursors. A mismatch can probe only the next new-cursor line, then the line two
positions forward, then the next old-cursor line, in that order. Each hunk starts
from its declared positions. There is no arbitrary backward search, global
offset scoring, whitespace folding, case folding or Unicode normalization.

Insertion checks later non-added patch records against the same current target
line to avoid duplicate insertion. A successful lookahead remains accepted even
if a later comparison breaks the lookahead, matching the pinned implementation.
The force flag used for recorded-base retry bypasses an addition's existing-file
refusal; it does not bypass hunk matching.

The source's omitted-count shorthand has unusual semantics: `-N` means old start
zero/count N, and `+N` means new start one/count N. The adapter preserves this
source rule. Ordinary successful Git parsing retains Git's standard unified-diff
semantics rather than being reinterpreted by the adapter.

Expanded-keyword matching is deliberately narrow in where it applies, but broad
within that line. A case-sensitive occurrence of `$LastChangedDate`, `$Date`,
`$LastChangedRevision`, `$Rev`, `$LastChangedBy`, `$Author`, `$HeadURL`, `$URL` or
`$Id` anywhere in a patch context/removal payload bypasses that entire payload's
equality check. A closing dollar sign and a matching target expansion are not
required. Added-line insertion lookahead still uses exact equality. Existing
context text is retained; removal deletes the actual addressed target line.

## Target encoding, BOM and line endings

`FileTextLines.cpp::Load` and `Save` provide the target format rules. Existing
target codecs and untouched line endings are retained. Inserted terminated patch
records use the target's predominant ending, with source CRLF fallback. A missing
preimage starts with the captured legacy code page, not the patch container's
codec; lossless representability is required. Explicit BOM transitions can
promote the result to UTF-8 BOM, including a pure addition, or remove a UTF-8 BOM
when the hunk's first-line flags request that transition. This is source behavior,
not a general request to transcode every target to UTF-8.

Patch payloads retain their original terminators for inspection, while any
terminated inserted record has source `AutoLine` semantics. A leading U+FEFF is
removed from a hunk payload and retained as a BOM flag. The source ignores
backslash-prefixed warnings, including `\ No newline at end of file`: the warning
does not retroactively remove the preceding record's ending. The Git engine's
existing exact final-newline behavior remains separate.

A loaded nonempty target has a final `NoEnding` record, including an empty final
record after an ending. A genuinely zero-byte file returns from source loading
before that record is added. BOM-only input is nonzero-byte input and retains its
empty decoded record. These states must remain distinct from absent files and
from a terminated blank line. Automatic PatchSave and explicit Keep/Delete Save
remain governed by the [patch application/save policies](PATCH-SAVE-APPLICATION-POLICY-PARITY.md).

## Filesystem and engine boundaries

The pure applicator returns a result and an exact input-byte witness; it does not
write a target or change the index. The repository integration retains the
captured file bytes, modes and permissions, path confinement, folder-access
scope, stale-input checks, generated-patch validation and publication path.
For decoded output with unchanged existing Git modes, captured permissions
survive Git's canonical executable mode recreation. Restoration uses a pinned root and parent/leaf descriptors,
refuses symlinks, verifies exact owned output bytes and mode, and checks the
opened file and named entry before changing permissions. New outputs retain
their actual umask-restricted permissions in subsequent owned receipts. A failure
or cancellation after publication retains the successful byte-write receipt
with a distinct warning; it does not claim rollback. Native explicit Save
requires a fresh read before accepting an unverified savepoint. Patch All
and Patch Selected continue to use captured AutoAdd, per-file progress,
cancellation and successful-file/warning receipts. Plain-folder application
does not initialize an index.

Binary payloads, symlinks, gitlinks and unsupported mixed records are not decoded
as ordinary text to make a failed Git command succeed. There is no blind fallback
from every Git error. Existing binary/symlink/deletion whole-state recovery stays
available through its existing route. Source `.rej` files are not a missing
implemented upstream feature: `Git/GitPatch.cpp` records an error string and
explicitly says reject files are unsupported; the rejected-hunk viewer in
`MainFrm.cpp::PatchFile` is disabled.

## Evidence and remaining acceptance

Parser and applicator fixtures cover Unicode and captured legacy codecs,
multi-file SVN/GNU headers, quoted paths, source offset/keyword rules, format
state, strict failures, Reverse/Strip, metadata retention, exact input witnesses
and cancellation. The connected repository/native checkpoint must additionally
exercise real selected/all application, recovery, mode/rename/copy publication,
original-byte Copy/Save, captured preferences, unsafe/stale refusal and actual
worker/window retirement with private repositories and hidden windows.

The dated record distinguishes completed checks from failures and unrun cases.
This scope does not establish full upstream parser acceptance, every external producer's
format, visual parity of every dialog, hosted CI success or physical Finder
acceptance. Remaining implementation and evidence are tracked in
[the adapter gap record](MERGE-PATCH-TEXT-ADAPTER-GAPS.md).

## Captured target encoding after discovery — October 23, 2026

Inspection, comparison and selected/all application must honor an explicitly
supplied target text policy even when discovery already selected the decoded
adapter. The patch container and target encoding are separate: a captured Unicode
patch retains its Unicode hunk text, while a legacy patch can be re-decoded from
its original bytes under the newly selected legacy codec. Re-decoding cannot
change accepted paths, record identities, rename/copy roles, modes or recorded
object identities.

The original target byte, mode and permission witnesses remain authoritative.
Changing an encoding choice does not refresh the review or accept later external
edits. Manual recovery may show text that requires another output encoding;
automatic publication still requires lossless encoding, and an unrepresentable
result remains available for an explicit manual encoding choice.

The hosted Core failure that exposed this propagation boundary and the focused
repair checks are recorded with
[the connected batch](qa/primary-layout-patch-encoding-2026-10-23.json).
