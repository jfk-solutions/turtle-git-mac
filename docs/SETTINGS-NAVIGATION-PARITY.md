# Native Settings tree — implementation in progress

Reference: pinned `Settings.cpp::AddPropPages`,
`7338078f8ddd924b8cddee35f512f2286072136d`.

The Settings scene now uses a native AppKit outline/sidebar and content pane,
replacing the crowded global toolbar tab row. General owns Dialogs, Commit and
Alternative Editor. Git owns Remote when a repository is open. Email, Merge
Editor, Saved Data, Blame, Unified Diff and Advanced remain available. This is a
projection of implemented pages, not the complete upstream page catalogue.
Commit and Merge Editor retain their existing macOS-specific grouping; source
Dialogs 1/2/3, Colors 1/2/3, tools and helper-app settings still need full mapping.

Rows use original upstream General, Dialogs, Git Config, Git Remote, Saved Data
and TortoiseUDiff artwork, plus the existing editor/mail/merge/blame assets. The
six added files are copied byte-for-byte from the pinned source with SHA-256
provenance in the asset manifest (128 assets). Sidebar icons are page icons and
remain independent of the context-menu icon preference.

Hosting controllers are retained per visited page. Revisiting a page uses that
controller, rather than recreating all its native/SwiftUI controls. Merge, Blame,
Alternative Editor and Unified Diff Appearance now initialize their drafts only
on first appearance. Git retains its source and draft when revisited in the same
repository; leaving still cancels owned reads and questions. Source changes or a
new repository reload the Git page. The hierarchy hint is presented once per
page instance unless its saved suppression flag is set.

Remote embeds the existing native form with Add/Save, Rename, Remove, tags,
three-state Prune, Push Default, key-file selectors and owned prompts. It captures
the repository/grant that created it; changing repositories cancels that model
and recreates the conditional page. Fetch uses the existing native workflow, and
remote changes refresh repository history/workspace state. Active remote tasks
now fence application termination even after their window disappears.

The Settings window delegates close decisions through a proxy that retains the
original SwiftUI window delegate and forwards its other events. Normal close and
page selection are guarded during Remote operations, child sheets and Git saves.
Forced closure ends outstanding sheets and invalidates owned Remote reads/work.
The proxy is removed when the host is dismantled. Sidebar navigation uses native
outline keyboard behavior, single selection, disclosure triangles and accessible
page labels; geometry and actual focus need verification.

## Shared property-sheet draft handling

The host now owns OK, Cancel and Apply for its implemented pages. Visited pages
register draft participants; Apply saves modified participants in page order and
stops at the first validation or save failure, selecting that page. Successful
earlier saves remain saved if a later page fails, matching sequential property
sheet behavior. OK closes only after successful Apply. Cancel discards pending
preference drafts; immediate actions such as clearing saved data, Remote Add/Save,
Rename/Remove and credential actions retain their existing source semantics.

Dialogs and Commit now keep preference drafts instead of saving each click.
Font, history limit, status/log colors, viewer appearance, Email, Advanced,
Alternative Editor, Merge and Blame participate in the same flow. Unified Diff
keeps both subpage drafts alive when switching Viewer/Appearance. Git and Remote
await their asynchronous save results. A native input shield prevents editing the
content while Apply is running, while owned confirmation sheets remain usable.
Application termination is guarded until active saves finish. Repository changes
remove the captured Remote participant before creating its replacement.

Standalone settings windows retain their own existing buttons and save behavior.

## Remaining section work and acceptance

- Remaining settings pages and exact source hierarchy, captions, grouping and
  helper application boundaries. Existing pages remain partial.
- Source page sizes/resizing, sidebar width, all light/dark content and original
  icon raster appearance; physical keyboard, focus and VoiceOver acceptance.
- Remote Fetch ownership, forced repository replacement/close, cached draft
  retention and signed sandbox grants across the complete Settings host.

The combined Debug build passes at this continuation, and three focused real-Git
configuration tests pass (1.193 seconds). The check compiled the accumulated
History and Settings changes; it did not exercise their complete native workflows.
No app or native receiver was launched, no full suite or App Store build was run,
and visual, focus, asynchronous sheet and sandbox acceptance remain open.
See `docs/qa/settings-history-batch-2026-10-11.json`. No complete application/dialog
certification is implied and inventory counts are unchanged.
