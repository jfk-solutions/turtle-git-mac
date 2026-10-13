# Git property-page parity

Reference: `src/TortoiseShell/GITPropertyPage.cpp/.h` and `IDD_PROPPAGE` in
`resourceshell.rc`, pinned at `7338078f8ddd924b8cddee35f512f2286072136d`.
The native replacement is `GitPropertiesWindow.swift`; its reader and atomic
index writer are `GitProperties.swift` and `GitPropertyIndex.swift`.

The window preserves the source ordering: Current Branch, Tracked Remote Branch,
Tracked Remote URL, HEAD, conditional Last Modified, two rows of mixed-capable
index checkboxes, Config, Settings and Show log. Native OK/Cancel/Apply provide
the containing Windows property-sheet behavior. Refresh and owned-operation
cancellation are macOS additions. Git configuration artwork is reused for the
new menu entry; no Windows MenuInfo bit is invented for the Explorer property page.
The Finder entry opens this independent window rather than altering system Get Info.

Current branch includes unborn and detached HEAD. Tracking uses the resolved
upstream ref and remote. A local upstream is displayed by its local branch name
rather than reproducing the source’s remote-prefix slicing. Config fields use
ordinary effective Git values and the source empty-to-false CRLF defaults.
HEAD author/date and the first nonempty message line are displayed. Git performs
message recoding to UTF-8. Dates are absolute and follow the app’s date/locale
preferences, with the property page’s long-date default and blank epoch-zero date.

Last Modified compares the same path’s object with every parent, excluding
histories of differing parents and retaining source fallback to the final walked
commit if no qualifying change remains. Missing HEAD paths are blank. It does
not follow renames or treat mode-only changes as content changes. The walk uses
Git CLI reverse-walk order; a compiled Windows/libgit2 oracle, clock-skew/large
history performance, encoding edge cases and all merge shapes remain unverified.

All selected indexed paths are required before displaying flags. The source’s
first index entry for a conflicted path is retained; other stages are untouched.
Uniform fields use two-state checkboxes and originally mixed fields permit an
indeterminate state. Executable/Symlink exclusion and hiding these modes when a
submodule is selected follow the source. Unchanged mixed fields preserve per-path
values. Initialized gitlinks can add the child Git page. Known parent contexts
are added only inside the captured repository grant; discovery never grants access.
Parent discovery without cached metadata and signed shared-admin permission
acceptance remain open.

Apply locks and checks the actual index against the loaded snapshot. Metadata
edits preserve objects, stat data, paths, stages and intent-to-add in index
versions 2–4 with SHA-1/SHA-256. Split indexes are materialized privately using
Git before editing. Cached tree/entry-offset/fsmonitor extensions are invalidated;
other parsed payloads are retained. Checksum/structural corruption, unsupported formats, stale inputs,
lock conflicts and cancellation before publication leave the original index
untouched. Publication uses atomic replacement with the original permissions.
The binary layout follows [Git’s index specification](https://git-scm.com/docs/gitformat-index).
These implementation assertions require the batch checks below; they do not
establish every sparse-index/extension combination or crash-durability scenario.

The model captures each page’s repository, paths, access and draft. Duplicate
Apply is refused; per-repository completion is recorded before proceeding to
another page. Multiple repository writes are not a single transaction. Busy
reads/writes and owned Settings block close/Quit; forced retirement cancels
owned work, fences late reads/navigation and refreshes live owners after an
already-completed write. Settings has an isolated captured context rather than
adopting another workspace’s repository. Log also keeps the captured paths.

The connected batch passed Debug compilation, seven focused Core cases (one
history fixture repaired and rerun), and six grouped native cases across system
and bundled Git. AppStore compilation and bundle validation passed before the
final title/checkbox-height adjustments; final Debug compilation covers those
adjustments. See [dated QA](qa/git-properties-2026-10-13.json).

Physical light-mode inspection covered the selected-file window, menu route,
source ordering, and Apply/restoration of assume-valid without changing working
bytes. The test-owned previews were closed. Dark-mode capture was not confirmed.
Native Finder/Get Info integration, actual Settings sheet gestures, broader
physical keyboard/tri-state/accessibility behavior, signed sandbox/App Store
execution and exhaustive history/index edge cases remain pending. No dialog is
certified as fully ported.

## Finder preference integration — 2026-10-13

The macOS property-window action now follows Settings placement and visibility,
including first-level and Shift-only choices. Its direct title remains Git
Properties without a duplicated Git prefix. Source MenuInfo rules/order remain
independently checked; the native adaptation is recorded separately in the
condition fixture and verified alongside the original Finder command sets.
