# New Branch/Tag dialog parity

Reference: `CreateBranchTagDlg.cpp`, `IDD_NEW_BRANCH_TAG`, BranchCommand,
TagCommand and `CAppUtils::CreateBranchTag` at the commit in `upstream.json`.

The separate native windows retain Name, Base On, Options and Description/Message
in the upstream order. Base On has HEAD (current branch), Branch, Tag and Commit
radio rows with aligned selectors and browse buttons. Branch and Tag share the
same implementation. App/Finder commands and log revision actions open it; the
latter preselect the exact commit rather than assuming HEAD.

Branch mode supports automatic/explicit/no remote tracking, Force, and Switch to
new branch, plus a multiline description saved to local Git configuration. Remote
selection suggests the remote branch name when the name is empty or still the
previous default. Editing that name disables automatic tracking. The switch
preference is remembered; bare repositories hide switch. Production creation with switch checked opens the shared native Switch result.
Its failure retains the new branch and offers Stash, Retry and Switch with merge.
Headless callers without a Switch presenter retain the earlier inline checkout
compatibility path and Retry checkout. Neither path recreates the branch.

Tag mode uses the text area as its message: empty creates a lightweight tag;
nonempty creates an annotated tag. Sign requires a configured signing key and a
message. The unchecked Sign option overrides Git's automatic tag signing setting.
Force permits updating an existing reference, subject to Git's checked-out branch
protection. Cross-type name collisions ask Continue/Abort before mutation.
Tag Push opens the native Push window scoped to the newly created full tag ref.
See PUSH-PARITY.md for its options and remaining differences.

## Evidence

Four real Git integration tests cover branch descriptions with mixed staged/later
unstaged changes, lightweight and annotated tags, forced tag replacement,
unchecked signing configuration, signing-message validation, remote tracking,
shared branch/tag names, invalid names/revisions and checked-out branch protection.
The complete Swift suite has 76 passing tests.

Native QA on the disposable documentation repository created a branch with a
multiline description, an annotated tag with a multiline message, and a second
branch with Switch to new branch checked. Git verified each reference and its
metadata and confirmed HEAD switched to the second branch. Index/worktree patches
matched byte-for-byte after all three operations. The fixture was returned to main.
A further native check created an annotated tag with Push checked, opened the
ref-scoped Push dialog, and sent only that tag to a disposable bare remote without
changing index/worktree patches. The actual native captures are `site/assets/create-branch.png` and
`site/assets/create-tag.png`.

## Remaining comparison work

- Full Browse References tree and selection-mode Log, revision history/completion.
- Interactive signing/key prompts and native signing verification.
- Native remote tracking/force/cross-name warning checks, failed-checkout retry,
  bare repositories, light appearance, keyboard, resizing and accessibility QA.
- Physical shared Switch ownership/cancellation and description retry acceptance;
  legacy callers without a Switch presenter still lack complete description recovery.
- Full settings/size persistence and a broader supported Git-version matrix.

This dialog remains partial in the upstream inventory. It is not full parity or
an App Store-ready release.

## Captured creation and Switch handoff

Production branch creation now follows CAppUtils::CreateBranchTag: create the
reference, run PerformSwitch when requested, then save a nonempty branch
Description after that result is acknowledged, even when checkout failed. The
native shared Switch model supplies its source-ordered success/recovery actions,
original icons and close policy. The options remain locked behind its sheet;
this retained ownership differs from upstream's closed options. Root refreshes
reference views after actual creation and repository views after Switch attempts.

Core createReference retains its existing default description behavior for old
callers. Production can defer it, then calls updateBranchDescription with captured
name/message, CR removal and trimming; a whitespace-only description removes
the prior config value. A foreign config lock preserves the created
reference and exposes Retry description; that retry cannot recreate or re-checkout
the branch and uses the original message. Surfacing/retrying a description failure
improves upstream's ignored SetConfigValue error; full partial-failure recovery for
legacy no-presenter callers remains pending.

Tag Push uses the submitted checkbox and full created tag ref, including after a
cross-name Continue warning. Cross-name Continue keeps original options/intent;
Abort clears the pending request. Load/create cannot replace running, warning or
completed states. Explicit HEAD presets select the HEAD radio. Production factory
requests receive separate options controllers so another requested base cannot
replace an existing draft. Close/Quit guards include chooser reads, mutation and
pending name warnings; closing invalidates late callbacks. Store creation and
post-Switch description writes check the retained root lease. Signed acceptance
remains unverified.

[Handoff QA](qa/branch-tag-handoff-2026-10-08.json) records six focused Core tests
and four-Git actual branch/tag creation and real Switch models: description timing,
failed-checkout actions/ref retention, config-lock preservation/description-only
retry, captured Push/cross-name choices, explicit HEAD/load/duplicate guards and
native close/Quit/invalidation. Actual Root factory/new-window/nested-sheet
interaction, UI warning defaults and Push destination remain physical acceptance
work. The hidden controller's view is removed before inducing a warning so the
receiver cannot display an alert; controls are hosted separately without a window.
No actual network Push occurs. Existing screenshots predate this completion flow.

## Full shared revision pickers

Create Branch and Create Tag now own the native all-reference namespace browser
and full typed-revision single-selection Log through `VersionPickerCoordinator`.
The reference tree/list supports local branches, tags, remotes and custom/notes
namespaces. A fresh return catalog classifies the canonical selection into the
Branch/Tag/Commit control; Cancel refreshes the original selection. Native revision
controls receive a once-only focus request, and branch/tag handoffs preserve the
unused commit draft. Log shows the typed ancestry, graph and details without the
Working Tree row and returns a full hash.

HEAD, busy, pending-name-conflict and already-created states prevent new picker
requests. Parent creation, competing requests, close and Quit are gated while a
picker or return catalog is pending. The shared owner rejects stale replies and
releases rejected/closed children. Name, description/message, Force and follow-up
options remain separate from chooser defaults; remote-name suggestions retain
the existing parent behavior. App factories configure canonical Log/Browse/Compare
context actions with the retained repository lease.

[Creation picker QA](qa/creation-pickers-2026-10-09.json) records hidden native
controller checks followed by actual private branch/tag creation at the chosen
Log revision, plus the existing captured handoff regression. Injected presenters
release parent focus and never order windows or show real sheets. Physical input,
sheet restoration, error/close-during-load recovery, visual/theme/accessibility,
complete browser/Log commands and signed acceptance remain pending. Existing
screenshots predate these routes.

## Owned creation cancellation and browser entry

Create Branch can now be entered from a selected remote ref in the native
reference browser. The source passes its stored object hash; this route retains
that immutable Commit base and refreshes the browser after closure. Standalone
and owned routes share repository interaction configuration. See
[reference browser parity](REFERENCE-BROWSER-PARITY.md).

Initial metadata and reference creation have owned cancellation tokens. Forced
closure cancels the chooser and its independent metadata/creation work, rejects
late state/error publication and preserves completed mutations. Core creation
threads cancellation through validation, existence/revision lookup, mutation and
description; ordinary error/default behavior remains compatible. Description
retry also owns a token. Routed checkout/switch completion and all failure variants
still need broader lifetime and physical/signed acceptance.
