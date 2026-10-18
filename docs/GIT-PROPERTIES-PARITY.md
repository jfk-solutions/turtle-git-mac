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
Git CLI reverse-walk order. Object IDs are read in bounded batches without
loading blob bodies; CR/LF names retain the scalar NUL-delimited reader. Missing
objects also use the tree reader, since a gitlink commit need not exist in the
superproject. A compiled Windows/libgit2 oracle, clock-skew performance, encoding
edge cases and all merge shapes remain unverified.

All selected indexed paths are required before displaying flags. The source’s
first index entry for a conflicted path is retained; other stages are untouched.
Uniform fields use two-state checkboxes and originally mixed fields permit an
indeterminate state. Executable/Symlink exclusion and hiding these modes when a
submodule is selected follow the source. Unchanged mixed fields preserve per-path
values. Initialized gitlinks can add the child Git page. Opening a sole repository root discovers its live registered parent using the
source `.gitmodules` rule, independent of Finder metadata. The parent Git
Submodule page precedes the child Git page. Refresh rebuilds derived pages and
retains the selected repository/path when it still exists. In scoped execution,
the primary grant must cover the parent before probing it; related metadata
grants do not expand that boundary. Missing/invalid primary scopes refuse
property reads and writes. Signed shared-admin permission acceptance remains open.

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

## Parent pages and batched history — 2026-10-15

The connected update adds live registered-parent discovery, source page ordering,
refresh of derived contexts, primary-grant read/write guards and bounded Last
Modified object queries. Log and Settings continue to use the selected page's
captured repository and paths. Forced retirement during parent discovery retains
operation accounting until its owned Git/helper processes settle and refuses
late context publication. No permission is acquired by discovery.

The object query uses Git's documented
[`cat-file --batch-check` protocol](https://git-scm.com/docs/git-cat-file),
validating one full-width object ID, an explicit submodule-OID response, or the
exact missing-expression frame per query. It preserves the existing source parent walk and mode-only behavior.
The 145-commit unchanged-file fixture checks three batch processes and no
scalar tree queries; this is a process-count check rather than a general
performance benchmark.

Validation results and limitations are recorded in the dated
[batch evidence](qa/git-properties-parents-2026-10-15.json). Native scope tests use
injected lease providers; they do not establish signed App Store acceptance.

The connected [captured Settings sheet family](SETTINGS-SHEET-PARITY.md) shares
guarded Close/OK/Cancel and actual-detachment ownership across Properties,
Unified Diff and Rebase, preserving their original preferences and pending work.
