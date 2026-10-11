# Native Settings tree — implementation in progress

Reference: pinned `Settings.cpp::AddPropPages`,
`7338078f8ddd924b8cddee35f512f2286072136d`.

The Settings scene now uses a native AppKit outline/sidebar and content pane,
replacing the crowded global toolbar tab row. General owns Dialogs 1, Dialogs 2, Dialogs 3, Message Editor and
Alternative Editor. Git owns Remote when a repository is open. Email, Merge
Editor, Saved Data, Blame, Unified Diff and Advanced remain available. This is a
projection of implemented pages, not the complete upstream page catalogue.
Message Editor and Merge Editor retain macOS-specific grouping. Dialogs 1/2
now follow the source separation for implemented controls; Dialogs 3 has the
scoped project fields described below. Colors 1/2/3, tools and helper-app settings
still need full mapping.

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


## Dialogs source-layout continuation (uncompiled and untested)

After the recorded shared-Apply validation, the next implementation section
separates Dialogs 1 from Dialogs 2. Dialogs 1 contains log limits/font, dates,
reference presentation, avatars, revision counters and Describe. It now includes
source AsteriskLogPrefix (default true), AbbreviateRenamings (default false), and
all five Describe preferences. Describe runs against the captured selected commit
with annotated-tags/all-tags/all-refs strategy, abbreviated size, long format and
first-parent choices. Missing describe names are omitted as upstream does. Late
results are fenced by the detail selection generation/cancellation. The message
pane follows the source hash/Describe/subject/body/Notes/Tag Info order, removing
CR and applying optional section asterisks.

Abbreviated rename paths share only directory prefixes/suffixes, with source
`{old => new}` formatting. Display/clipboard path cells use the preference; actual
Git paths and operations remain unchanged.

Dialogs 2 has source Misc and Commit groups. Progress auto-close, cancellation
confirmation, execution timings, Trash, unchanged-reference filtering and tag
sorting appear with completion, history-limit, selection/missing and comment-strip
controls. Message-editor-specific formatting and completion extras remain on
Message Editor and cannot write stale source Dialogs 2 preferences when applied.
The shared `MaxHistoryItems` key now drives Commit and Merge histories, with a
fallback/migration for the earlier Commit-only key.

Remaining implementation in this section: persistent log cache; Sync startup
position behavior; operation notification sounds; FETCH_HEAD choices and .mailmap
preference coverage; Dialogs 3 scoped project preferences and source physical
layout/keyboard/visual acceptance. No disabled or inert toggles are used to stand
in for these missing behaviors. Inventory remains unchanged. This continuation
has received source/diff review only; the earlier build/tests do not cover it.


## Dialogs 2 behavior continuation (uncompiled and untested)

The remaining source Misc controls are now implemented alongside the earlier
controls. `UseMailmap` defaults true and selects canonical author/committer
formatting in history reads; Log, Sync projections and version-picker history
honor their preference store. Reference Browser skips its mailmap lookup when
disabled, and full Log clipboard details use the same choice. Raw amend-author
identity reads explicitly remain raw; a display mapping does not rewrite an
original author's identity.

`BranchesIncludeFetchHead` defaults true. Version catalogs opt in to a
`FETCH_HEAD` entry only when the file contains exactly one for-merge line naming
an existing commit. Switch, Merge, Export, Reset, revision comparison and Format
Patch catalogs use the choice. The normal reference catalog remains real refs
unless a caller explicitly opts in. Switch treats a selected FETCH_HEAD as a
detached commit (or a new branch at that commit), rather than passing its pseudo
name as an existing local branch. Operation validation remains available for a
captured FETCH_HEAD even if the display preference is later disabled.

`SortTagsReversed` additionally governs Switch/Merge/Export tag lists. Sync
startup positioning follows the source sequence of 30-point offsets, cycling
through five positions and clamping to the selected screen's visible frame.

`NoSounds` now gates native terminal error/notification sounds for shared progress
models and Sync operations. Normal application startup enables these sounds;
headless receivers remain silent unless explicitly enabled. Recording deduplicates
outcomes across completion/close and resets between retries. Mid-operation warning
alias fidelity and audible/physical acceptance still require review.

Dialogs 2 Apply validates the source 1–100 timeout/history ranges. Changes above
have received source/diff review only. The grouped build/core QA record predates
this continuation. Persistent Log cache, Dialogs 3 and full native/visual/sandbox
acceptance remain open. No dialog certification or inventory count has changed.


## Persistent cache and Dialogs 3 backend continuation

Dialogs 1 now exposes Enable Log Cache with persistent changed-file records;
see LOG-CACHE-PARITY.md for its scope and unverified acceptance. The previous
paragraphs' pending-cache statement describes the earlier checkpoint.

Dialogs 3 backend models are implemented for `tgit.projectlanguage`,
`tgit.logminsize`, `tgit.logwidthmarker`, `tgit.warnnosignedoffby` and `tgit.icon`.
Reads support Effective/Local/Project/Global/System. Effective honors the shared
system/global → .tgitconfig includes → local/worktree/command hierarchy. A missing
project file gives inherited values; bare repositories read HEAD:.tgitconfig
through an owned temporary file. Effective fields use read-only default values.

Writes allow Local/Project/Global and reject System/Effective, Local/Project
without a repository, and Project in a bare repository. Field order matches
SetDialogs3; inherited fields unset their key. NUL values are rejected before
writes. Errors stop the sequence and report that earlier fields may already have
been saved. Local/global remain normal Git configuration files; Project writes
.tgitconfig and may require an ordinary commit to share with collaborators.

The native Dialogs 3 page now implements the five source fields in the source
Commit/Dialogs groups, Effective/Local/Project/Global/System selectors, inherited
fields and Local/Project/Global save destinations. Shared Apply saves in source
field order; Cancel restores drafts. Cross-destination confirmation, hierarchical
configuration hint/suppression and sandbox folder authorization use owned sheets.
Read/chooser callbacks are fenced on page departure and closure. Repository-bound
Git/Dialogs 3 drafts are removed when the settings repository changes. Shared
Apply detects participant replacement before saving queued pages.

Commit now enforces the configured minimum message length (UTF-16 units, as in
the Windows source). Commit, Merge and Rebase use native NSTextView project
language/disable settings and the configured character margin. Windows locale
IDs map through CoreFoundation; orthography is document-specific. Commit's
project icon uses the native window document icon, with security-scoped icon
bookmarks and fallback to the repository icon. This is a macOS adaptation of the
source taskbar overlay, not Finder status badges or a Dock overlay. Other dialog
window project icons still need integration.

These additions and the preceding Dialogs/Log cache changes remain **uncompiled
and untested**. This checkpoint deliberately adds implementation before another
combined section check. Native source-layout comparison, spelling support,
keyboard/focus, scope changes, sheets, signed sandbox permissions, save failures,
light/dark rendering and full displayed acceptance remain open. Earlier passing
QA records do not cover these additions. Inventory counts remain unchanged.
