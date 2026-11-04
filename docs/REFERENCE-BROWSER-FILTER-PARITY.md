# Reference browser filter publication

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
`BrowseRefsDlg.cpp::OnEnChangeEditFilter`, `OnTimer` and
`OnClickedInfoIcon` defer typed input and field-mask changes for 1,000 ms.
`OnClickedCancelFilter` clears immediately. `FillListCtrlForTreeNode` and
`FillListRefLeafs` rebuild the selected namespace's displayed references.

The native browser retains visible draft query text and Refname/Subject/Authors/
SHA-1 choices while its last accepted reference list remains stable. Each edit
replaces one owned one-second delay. Publishing the latest draft filters and
sorts the catalog once, intersects the existing selection and retains its current
last-selected reference when still displayed. The shared query parser, relative
reference names, Unicode byte identity and namespace rules remain unchanged.

Escape, the search field's empty/cancel action, explicit refresh and namespace
changes apply immediately and cancel the superseded delay. Changing sort order
reorders the accepted rows without prematurely applying an unfinished draft.
Nested-reference and merged/unmerged changes still perform their existing owned
catalog read, with the latest draft applied to its accepted result. Current Branch
still resolves live HEAD independently of displayed rows or the filter.

Captured menus retain the actual accepted rows when opened. Draft changes retire
older menus, and accepting a delayed projection retires menus opened during that
delay as well. A pending filter alone does not disable OK or replace the displayed
selection with a future query's results. Child dialogs, inline Rename, reads and
Quit confirmation cancel pending publication; still-editable owners can resume
an unaccepted draft after those owners release. Close invalidates the request and
retains its cancellation accounting until the delay actually returns. Application
Quit pauses/cancels live filter delays and returns Later while they drain, then
continues the existing document/operation Quit policy once. If a different owner
declines Quit, only still-live editable browsers resume their latest unaccepted
draft; closed owners cannot restart filtering. Duplicate Quit requests share the
same drainage and completion reply.

The filtered/sorted projection is cached by accepted catalog and presentation
inputs. Native table updates reuse row signatures and selection-index projections
while only draft input changes. New metadata at the same reference name, accepted
filtering, namespace/nesting/sort changes and actual date-format/locale/time-zone
changes invalidate the relevant cache. Relative dates update only the visible date
cells on an owned timer; closing/dismantling the native table stops that timer.
Layout, column menus, selection reconciliation and native focus remain live.
No loading strip or additional vertical UI element is introduced.

The [connected checkpoint](qa/reference-filter-publication-2026-11-05.json)
records actual validation after the implementation freezes. The native filter
receiver uses actual search controls and table updates, held delay completions,
private repositories/preferences, exact selection/menu ownership and unchanged
HEAD/index/file witnesses. Existing source-form, presentation and captured-menu
families remain regression gates. No Core algorithm changed. Full hosted,
physical keyboard/VoiceOver, signed Finder/sandbox and complete source/dialog
acceptance remain separate requirements; this family is not whole-port completion.
