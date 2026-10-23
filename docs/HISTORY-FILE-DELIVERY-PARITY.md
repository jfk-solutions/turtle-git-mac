# Historical file comparison and Browser transfer delivery

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
This connected implementation batch covers Blame parent/origin comparison delivery
and Repository Browser selected historical transfers. It does not certify the
whole Blame/Browser dialogs, Finder interoperability or the full application.

## Blame comparisons with several origins

`src/TortoiseGitBlame/LogListBlameAction.cpp:116–139` launches a comparison for
every attributed parent filename, retaining the selected parent's revision and
Shift's alternate tool choice. The native model already calculated those origin
snapshots, but dispatched each separately to the workspace. The first dispatch
set workspace busy; subsequent origins were silently refused.

The model now sends one ordered owned request containing every existing snapshot.
A single workspace comparison session asks about the aggregate file count and
retains the initiating window, preferences, access, diff backend and explicit
alternate-tool choice. Each origin keeps its own parent, destination, old rename
path and file record; grouping does not deduplicate or rebuild the Git paths.
The original callbacks remain for independent consumers, while the real workspace
installs the owned aggregate route.

The Blame request retains its counter and access until the callback actually
returns. Reload, document replacement, close and Quit cancel pending requests.
The shared comparison session observes cancellation even if the source window
remains open, dismissing its owned question. Late answers cannot create viewers.
Workspace termination also cancels these sessions and includes them in pending
repository work. Accepted viewers have their own normal read/close ownership;
closing the source after their presentation does not undo the accepted opening.

## Repository Browser selection transfers

`src/TortoiseProc/RepositoryBrowser.cpp:1355–1463` recursively expands selected
folders and tree/root nodes into an ordered path list. Gitlinks participate as
names even when they have no file-content representation. `src/Git/GitDataObject.cpp`
provides that complete list as text in addition to historical file contents.
The common drag root controls receiver names; the repository root does not add
an extra repository-named folder around the entire export.

An immutable receipt captures actual native selection order, the peeled object
and tree, repository access and materialization backend. Recursive leaf paths
include gitlinks and use the source ordinal UTF-16 traversal with CRLF text.
Git paths retain their slash spelling; file receivers use native promised names.
Real top-level items remain separate promises; a gitlink-only selection is text
only. Root-tree delivery exposes the top-level items without a repository-name
wrapper, while a nested-folder drag keeps its leaf folder name.

Recursive metadata is collected asynchronously from the pinned tree, separately
from ordinary browsing, with a 100,000-entry, 16 MiB and 128-component depth
budget. Direct file/gitlink selections need no recursive inventory. A bounded
whole-tree failure can retry a smaller selected subtree; incomplete inventories
are not published as complete path lists. A loading/refused folder transfer
reports its state rather than silently omitting paths. Native sessions retain
accepted receipts through delivery; refresh/close prevents new gestures without
retargeting already accepted content. Existing exclusive receiver publication and
provider-owned temporary-copy cleanup remain in use.

Existing multiple file promises and deferred folder exports remain established
behavior; they are not claimed as newly implemented multiselection.

## Validation checkpoint and remaining acceptance

[The grouped checkpoint](qa/history-file-delivery-2026-10-23.json) records 21
relevant Core methods, ten distinct native case/engine pairs and the standalone
provider transport passing across recorded attempts. Fourteen receiver attempts
were reaped and independently confirmed absent. The initial app build exposed
a private-setter compile error; native ownership diagnostics then proved a real
contents-table disabled-state bug after sheet dismissal. Persistent enabled state
now follows the model while live callbacks retain sheet guards. Only affected
checks were repeated. The final app build exited zero with one generic “failed
with exit code 0” diagnostic.

The standalone transport runner explicitly compiles shared production transfer
primitives after their extraction from the file-list adapter. Its fixture retains
all original assertions, isolates newly prepared exports and explicitly chooses
the CLI backend for a real started-Git Progress cancellation. The initial generic
assertion did not identify its exact failure stage; the record does not invent one.

Exact snapshot and Browser path identity is covered here; reuse keys for distinct
canonical-equivalent historical comparison windows are addressed by the separate
[historical viewer continuation](HISTORICAL-WINDOW-IDENTITY-PARITY.md), whose dated
evidence retains its own validation scope.
Physical Finder/other-app drag reception,
Windows pixel/layout equivalence, minimum-version/signed grants, full hosted CI
and complete upstream dialog parity remain separate work.
