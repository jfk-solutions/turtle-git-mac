# Reflected names in Merge unified patches

This partial workflow audit uses pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`, specifically
`src/TortoiseMerge/MainFrm.cpp::OnEditCreateunifieddifffile` (lines 2897–2975),
`src/TortoiseMerge/AppUtils.cpp::CreateUnifiedDiff` (lines 77–111), and
`src/Git/GitAdminDir.cpp::HasAdminDir`. The earlier entry notes' reference to
`TryGitUnifiedDiff` was inaccurate: no such symbol exists in the pinned source.
The behavior is the post-generation rewrite in the native editor action.

The two-file editor's **Create unified diff file** action compares the saved
input bytes, then uses the active panes' reflected metadata to rewrite ordinary
text-patch headers when both reflected paths belong to the same working tree.
Descriptive captions do not replace filenames. Switching sides carries each
reflected path with its corresponding input. Reflected paths need not exist;
missing descendants can still describe a path in an existing working tree.
An empty, relative, administrative, inaccessible, invalid or different-repository
pair keeps the originally generated labels. Separate linked worktrees do not
share a root merely because their Git object database is shared.

`MergeReflectedPatch` resolves roots off the main actor through Git's normal
cancellable process owner, without a shell or an input-file read. Existing
sandbox permissions still apply; reflected metadata grants no file/folder
access. It retains the supplied lexical UTF-8 path spelling, matching a Git
canonical root to an original ancestor by filesystem identity so system aliases
such as `/var` remain usable. The resulting repository-relative labels are
always quoted, as in source, with Git C-style escaping for quotes, backslashes,
control characters and non-ASCII UTF-8 bytes. This escaping deliberately repairs
the source's unsafe literal interpolation for such filenames.

Only `diff --git`, `---` and `+++` headers change. The index line and every hunk
byte, CRLF and no-newline marker remain untouched; arbitrary hunk bytes are never
decoded. Empty output, binary differences, mode-only changes, additions/deletions
and unrecognised header layouts keep Git's normal generated output, as the
source rewrite's text/index/hunk guards require. The standalone
`/createunifieddiff` command remains a raw no-index output path: source calls
`CreateUnifiedDiff` directly there and does not perform the editor-only reflected
rewrite. Read-only two-file comparisons retain this comparison/export action;
they cannot thereby mutate a pane or satisfy a requested merged-result Save.

The chooser, selected saved inputs, active metadata, cancellation token and
preferences are captured for one native export request. Existing output owner
checks reject a late chooser reply after retirement; completion waits for the
owned task to drain. No extra input/output authority is acquired from reflected
names, no repository configuration is modified, and no command is auto-staged.

## Grouped checks

`MergeReflectedPatchTests` covers applicable repository-relative output, missing
reflected descendants, distinct repositories and linked worktrees, administrative
paths, byte-preserving hunks, NFC/NFD literal spelling and Git path escaping,
unrecognised/binary/mode/add/delete layouts, and pre-cancelled discovery.
`docs/qa/merge-reflected-patch-native-2026-10-18.swift` exercises the actual native
export action, read-only comparison eligibility, Git apply, swapped panes,
cross-repository fallback, unchanged source bytes and held-chooser retirement.
The parent batch owns execution and records actual outcomes; fixture existence
alone is not a passing result.

Full source Open/EditorConfig reflected-path behavior, physical menu/focus and
light/dark/accessibility parity, signed sandbox access and minimum-OS/Intel
acceptance require their own evidence. This audit certifies no complete dialog,
Merge editor or whole-application parity.
