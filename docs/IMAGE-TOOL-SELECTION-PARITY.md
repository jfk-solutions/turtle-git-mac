# Standalone IDiff selection and local image entry

Pinned baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
Source anchors: `TortoiseIDiff/TortoiseIDiff.cpp:68–75,116–155`,
`MainWindow.cpp:178–200,760–830`, `MainWindow.h:33–39`.

## Connected native workflow

The [local image tool](IMAGE-TOOL.md) has a dedicated launch mode and static
Settings-only scene. It creates no repository workspace and needs no Git runtime
for plain image entry. Parsing, authority, captured bytes, native panes,
completion, cleanup and optional Git resolution form one owned workflow.
Two-file commands reuse the image comparer and Load Images chooser; three named
inputs reuse the image conflict pane controls with standalone titles and original
path provenance. Menus, toolbar, keyboard input, appearances, information, frame
controls, preview drops and color chooser retain their existing native consumers.

Mine/Base/Theirs order and selected-side codes follow the source enum (1/3/2 in
pane order). Source No to the post-copy Resolve question leaves the copied result
and window open. Unmerged stages are checked only after copy under actual
repository/metadata authority. Explicit Yes uses a binary-safe saved-output
publisher, an exact captured stage packet and the existing private-index CAS.
A failed stage does not discard or repeat the successful copy.

The immutable document owns original containers independently of preview
rasterization and frame choice. Selected bytes, input identities, output identity,
mode and directory plans are checked through the atomic write callback.
Same-path result writes advance only their private validation witnesses; each
pane's original selection bytes remain. This is an explicit captured-display
adaptation to the source CopyFile path reread. Distinct hard-linked results use
atomic replacement. Decoder retirement and pending drops retain actual work
accounting until completion; return to the waiting caller happens only after
grants, panels, editors, helpers and optional cleanup drain.

## Source distinctions and remaining work

The source assigns peer picture windows only in two-image comparison mode.
Its three-pane width/height/link handlers have no peer to couple, and selection
menus omit them. Their handler presence alone is not a missing three-pane linking
feature. Source `FileType::Mine=1` collides with its generic startup failure; the
explicit macOS protocol uses64 for request/startup failure to distinguish it
from an accepted selection. Window close/Cancel remains0.

Source cleanup's unconditional DeleteFile is adapted to captured identity/bytes
and live deletion grants. Changed inputs and an explicit same-path result cannot
be removed as temporary files. Symbolic-link input/results, partial two-role
selection and HWND notifications are explicit boundaries. Physical/signed
permission panels, external caller process acceptance, platform/keyboard/IME
coverage, all source UI states and complete full-port parity remain separate.
The report-column context-menu icon gaps found during this review remain queued
as their own visible report-control batch.

## Grouped checkpoint

The grouped checkpoint passed 37 focused Core methods covering the new parser,
captured documents and binary resolution alongside existing output-writer
compatibility. The complete standalone native workflow passed with system and
bundled Git. Six existing toolbar/conflict/drop engine cases also passed before
the later dedicated selection/launch repairs; their unchanged default routes
were not rerun. Actual light/dark content captures were reviewed and added to
the guide. They exclude the frame and toolbar.

The inactive receiver uses a private key-window witness, native key notifications
and explicit AppKit update delivery for menu ownership checks. Physical focus
and signed permission-panel acceptance remain separate. The
[checkpoint receipt](qa/image-tool-selection-2026-10-29.json) retains failed
attempts and repairs; [capture provenance](qa/image-tool-selection-captures-2026-10-29.json)
records the actual authored inputs and PNG hashes. No installed-build or full
hosted acceptance is inferred. Installed build33 predates this family.
