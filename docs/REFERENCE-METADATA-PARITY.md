# Reference metadata text and literal identities

This family fixes two end-user boundaries exposed by the hosted macOS run at
`b97ddfe2`: legacy-encoded reference display metadata could fail the selected
library reader, and a valid tag beginning with a combining mark could lose its
namespace during Switch classification. The source comparison uses pinned
TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.

## Source and native contracts

`src/Git/GitRev.cpp:99–130`, `ParserFromCommit`, selects the commit's declared
encoding and uses it for the message and all four author/committer name/email
fields. An absent encoding uses UTF-8. `src/Utils/UnicodeUtils.cpp:33–207` maps a
finite, case-insensitive code-page alias list; an unknown name falls back to
UTF-8. Native `CommitMessageEncoding` in `Sources/TurtleGitCore/CommitMessage.swift`
uses that alias policy. UTF-8 display replaces malformed subsequences; supported
legacy decoding has an explicit error when conversion is unavailable or fails.
Native commit text does not support UTF-16/32 Git message encodings.

The actual pinned Ref Browser reader has a narrower behavior:
`src/Git/GitRevRefBrowser.cpp:157–162` uses `git_commit_summary` and default UTF-8
conversion for the subject and signatures, without passing the commit's declared
encoding. The Mac correction deliberately makes those display fields consistent
with native typed commit display and permits legacy commit metadata to reach
Reference Browser and Rebase consumers. It is a compatibility extension to that
specific pinned Ref Browser path, not a claim that upstream already performs
this conversion there. Summary formatting retains the existing library
first-paragraph behavior. Annotated tags have no commit encoding header and
retain their UTF-8 display path.

Reference names, symbolic targets, upstream names, paths and object IDs remain
literal identities, separate from display-text decoding. No replacement-character
conversion, case folding or canonical Unicode normalization is applied to make
an invalid or different identity look valid. Namespace classification and prefix
removal must use exact UTF-8 bytes; a combining mark immediately after
`refs/tags/` belongs to the tag name.

## Connected implementation scope

The helper's `local_reference_row` prepares valid UTF-8 display metadata before
sending its strict typed reference frames. Its ordered 156-entry alias table
matches `CommitMessageEncoding`, including first-match behavior for duplicate
aliases; an iconv-recognized name absent from that table still uses the source
unknown-name UTF-8 fallback. Commit subject, author name/email and committer
name/email use that coherent policy. Recognized legacy conversions are strict;
unavailable or malformed encodings, unsupported Unicode message encodings,
embedded converted NULs and exhausted conversion bounds fail visibly.
Cancellation, malformed protocol and actual helper failures remain visible;
a failed library reader never silently changes to CLI.

The CLI catalog also reencodes commit display fields to UTF-8. It batches up to
200 unique commit OIDs through explicit pretty-format `git log` reads and overlays
only subject and signature text. Notes, decoration and signature display are
explicitly disabled so configured log presentation cannot corrupt the metadata
frames. Literal names, object IDs, timestamps, tag rows and subsequent mailmap
handling retain their existing contracts. Framed replies
must contain exactly the requested distinct OIDs and field count. The CLI path
uses Git's supported charset names; the helper uses the finite source alias
policy above. They are not claimed identical for arbitrary charset labels.

Core Switch and selected-helper Reference Browser catalog filtering and
classification preserve exact namespace prefixes, the full suffix and distinct
canonical spellings. Combining-mark initial components remain valid in heads,
tags and remote branches. Browser heads-only, heads-and-tags and remotes-only
scopes include only the requested namespaces. This affects real catalog selection
and accepted checkout preparation, while ordinary checkout transport remains CLI. Existing command-mask and master-switch choices are not
reassigned by this correction. The follow-up remote-name catalog receives the
same accepted backend snapshot rather than reloading mutable defaults midway
through a Reference Browser read.

The batch also corrects retained fixture assumptions exposed by the same hosted
run: wrappers must intercept their intended current command/backend, and
command-observation tests must distinguish public command receipts from transient
invocation configuration and later metadata reads. Behavioral assertions about
actual output, mutations, ownership and failures are retained.

## Validation status and limits

The new `ReferenceBrowserTests.testScopedCatalogsAndCheckoutRetainCombiningInitialComponents`
forces CLI and selected-helper paths, retains combining-mark initial names in all
three namespaces, and checks both inclusion and exclusion for the scoped catalogs.
The original failing nested-Unicode test remains unchanged.

`LocalReferenceEncodingTests` adds six focused methods covering Windows-1252
summary and all four signature fields, an iconv-known/source-unknown charset,
maximal UTF-8 replacement, tag display versus unchanged raw tag bytes, malformed
recognized legacy encoding refusal, and strict invalid reference-name refusal.
The grouped Core run attempted 48 methods: 47 passed and one retained fixture
failed because its command/backend instrumentation no longer matched the
captured metadata path. That fixture was repaired while retaining CLI inventory,
master-selected follow-up reads and unavailable-helper refusal. Its one affected
method then passed. All 48 distinct methods pass cumulatively, including the six
methods that failed in the historical hosted run; this was not a full Core rerun.

The rebuilt universal helper and its actual arm64/x86_64 execution checks pass.
The Debug app build exited zero without a contradictory exit-zero compiler
diagnostic; other build warnings remain in its log. The retained native local
reference workflow passes with both Git engines. Both owned receiver PIDs were
reaped and independently confirmed absent. Its log contains zero-bounds
`NSSplitView` resize warnings during offscreen construction, so this is neither
a clean-log claim nor a new complete visual acceptance result.

[Family evidence](qa/reference-metadata-family-2026-10-24.json) preserves the
historical hosted failure, the initial local failure and focused repair, log and
artifact hashes, actual validation scope and remaining limits. Hosted build 56
was still building at observation and predates these uncommitted metadata
changes; it is not a pass for this batch.

Remaining acceptance includes the exact macOS conversion availability for all
source code pages, physical Reference Browser/Switch/Rebase interactions, signed
runtime deployment and a new complete hosted integration run. The repair does
not certify all reference workflows or every upstream dialog.
