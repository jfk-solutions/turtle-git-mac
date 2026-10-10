# References commit is on

A native modeless dialog now opens from Log's **Show branches this commit is on**
menu entry. Core and native interaction checks pass with system and packaged Git;
Core checks also pass with isolated Git 2.39.5. The dialog and its seven controls
are tracked as partial. Physical and signed acceptance and complete source parity
remain open.

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

## Native implementation checkpoint

Source: `1769e2c738e9b078e6c377205f5124b23bd010db`.
See [the native verification record](qa/commit-containing-refs-2026-10-10.json)
for exact checks, capture provenance and remaining acceptance.

`CommitContainingReferences.swift` pins the requested commit, reads mailmapped
metadata and Git's configured abbreviation, and queries all containing local/
remote branches and tags with `for-each-ref --contains`. It reads stdout separately
from diagnostics, includes symbolic remote HEAD and recursively nested annotations,
ignores blob tags and other namespaces in containment, and preserves full exact
reference identities. Reference completion includes the other namespaces too.
Empty filters retain all rows; other filters use literal case-sensitive UTF-16
matching. Finder collation supplies natural ordering, with byte ordering for ties.
This is a native adaptation, not certification of Windows punctuation/policy ties.

`CommitContainingReferencesWindowController` preserves the top revision/chooser,
subject and Show log row, headerless colored reference list, and bottom Filter.
It routes all one/two/many selection menus, range direction, comparisons, unified
diff, copy and the three owned pickers through native controllers. Plain parent
navigation selects; Shift highlights. Reads, deferred edits and late replies are
owned by the child; forced parent closure cancels the child, while active picker
sheets fence ordinary close and Quit. The original checkpoint refreshed completion with each query. A follow-up now
loads it independently of commit validity, caches it for the dialog lifetime and
reloads it on F5. Every locale/keyboard route has not been certified.

`CommitContainingReferencesTests` uses real repositories for descendant vs tip
containment, nested tags, symbolic remote HEAD, blob-tag exclusion, mailmap,
configured abbreviation, packed distinct Unicode refs, literal filtering, detached
HEAD, bare repositories, invalid inputs, cancellation and byte preservation.
`scripts/test-commit-containing-refs.py` compiles and runs a real hidden AppKit
receiver with private preferences and disposable repositories. It checks actual
menu target/action dispatch, one-second filter, Escape, owned Browse References/
Log/Reflog picker cancellation and reference acceptance, rejection of an obsolete
reply ignoring cancellation, and the real parent Log table menu/close route.
Actual native content captures were inspected in light and dark appearances.
They show the corrected right-aligned Show log row and original colored icons;
window chrome is excluded. These checks do not establish physical input, VoiceOver,
installed Finder or signed sandbox acceptance.

## Completion cache follow-up

The source’s `m_bRefsLoaded` check runs before it validates the revision. Native
initial empty/invalid entries now also initialize completion. Ordinary revision
queries update containment without rereading all reference names; F5 invalidates
completion and reloads it while preserving the entered revision. Forced close and
superseded queries reject stale completion publication as well as commit results.

Four Core tests pass with system, isolated old and packaged Git. The added test
covers independent completion in an unborn repository, non-commit namespaces,
cancellation and omitted repeated completion reads. The native receiver passes with system and packaged Git for initial empty/invalid
completion, new references appearing in containment while completion stays cached,
F5 refreshing completion without changing the entered revision, and restoration
after deleting the fixture reference. Existing picker/menu/stale-result/close
checks still pass. Source checkpoint: `9400d1d191bf52eef187db78dd1ee54e77bdd690`.
See [the follow-up verification](qa/commit-refs-completion-2026-10-10.json).

Completion-read failure follows the source’s ignored `GetRefList` status: cache an
empty list, continue resolving a typed revision, and retry completion only on F5.
The completion phase uses the same generation/cancellation checks as commit reads.
Controlled completion failures and cancellation-ignoring completion replies now
pass native checks with both engines: failed completion is cached without blocking
a valid typed commit; F5 retries; replacement and close reject an obsolete reply.
The completion-read counter stays unchanged for ordinary queries. Final native
checkpoint: `dc2d8d5c71a860b798bcb84a41ef6a2c239048cc`.
