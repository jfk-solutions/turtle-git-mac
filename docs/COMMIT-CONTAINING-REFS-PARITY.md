# References commit is on

This upstream workflow is missing from the native Log window. The source audit
below defines the implementation work; it does not establish a completed port.
The dialog inventory remains `pending-review`.

## Source and entry point

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
`GitLogListBase.cpp` adds **Show branches this commit is on** with
`IDI_SHOWBRANCHES` for one selected real commit, subject to its menu mask.
`GitLogListAction.cpp` opens a modeless `CCommitIsOnRefsDlg` initialized to that
commit. This is different from the branch/tag decorations attached to the row:
the dialog finds references whose tips contain the commit in their ancestry.

`CommitIsOnRefsDlg.cpp/.h`, `IDD_COMMITISONREFS` and
`CGit::GetRefsCommitIsOn` define the complete workflow.
Source blob IDs and required checks are in
[the audit record](qa/commit-containing-refs-audit-2026-10-10.json).

## Controls and data

The resizable native replacement needs the same arrangement:

| Upstream control | Role |
| --- | --- |
| `IDC_COMMIT` | Editable revision at the top, initially the selected commit; reference completion |
| `IDC_SELREF` | Adjacent chooser menu: Browse References, Log, Reflog |
| `IDC_STATIC_SUBJECT` | Read-only abbreviated hash and subject; author/date tooltip after mailmap |
| `IDC_LOG` | Show log for the resolved commit |
| `IDC_LIST_REF_LEAFS` | Headerless multi-select list of full reference names, original tag/local/remote type icons |
| `IDC_FILTER` / `IDC_LABEL_FILTER` | Bottom Filter field with clear affordance |

The source query includes local branches, remote branches and tags containing the
resolved commit, including descendant tips. Its CLI route uses `branch -a
--contains` and `tag --contains`, normalizes symbolic remote names and omits the
detached pseudo-branch. Its libgit2 route resolves symbolic refs and peels tags.
Results use `LogicalCompareBranchesPredicate` ordering and deduplication. Native
implementation must preserve literal reference spelling and handle nested tags;
a tip-equality query would lose required functionality.

Revision edits and filter edits each debounce for one second. Filtering uses
literal case-sensitive `CString::Find`. Clear filters immediately; clear previous
rows and subject while loading. Busy/invalid/empty states gate Show log and Filter.
F5 refreshes reference completion as well as the containment result. A macOS
asynchronous adaptation must reject stale replies and cancel/reap owned reads on
forced closure, rather than reproduce the source thread's error-path lifetime bugs.

## Selection, menus and ownership

One reference offers Show log, Browse repository, Compare with working tree
(only with a working copy), and Copy. Two references offer Compare revisions,
Unified diff, both directed two-dot and symmetric three-dot Log ranges, and Copy.
More than two references still support Copy. Preserve upstream menu order,
separators and original icons. Range direction follows the last selected reference;
comparison uses table order. Copy full names in list order with a trailing newline.

The top Show log uses the resolved commit, independently of list selection.
Chooser acceptance updates the revision and reloads; cancellation preserves the
entry and focus. Double-clicking a reference in the modeless child asks the parent
Log to navigate to that reference. Command-A/Command-C belong to the list when it
has focus. Escape clears a nonempty focused filter before closing the window.

The native workflow must keep its repository permission lease and route comparison,
Log, browser and picker children through existing controllers. Busy and child-sheet
gates, parent/child close cleanup, read cancellation, unchanged repository bytes,
physical light/dark layout and signed sandbox acceptance all need direct evidence.
