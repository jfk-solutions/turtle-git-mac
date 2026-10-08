# Switch/Checkout dialog parity

Reference: `src/TortoiseProc/GitSwitchDlg.cpp`, `Commands/SwitchCommand.cpp`,
`IDD_GITSWITCH` in `src/Resources/TortoiseProcENG.rc`, and the shared
`CChooseVersion` implementation, pinned to `upstream.json`.

## Implemented comparison

The separate native window preserves the two groups and control order: Switch To
with Branch, Tag and Commit radio rows and aligned selectors, then Option with
Create New Branch and its name, force and Merge, three-state Track, and Override
branch if exists. OK, Cancel and Help occupy the bottom row. Native controls replace
Windows widgets. Branch/tag selectors retain full reference identity internally.

Local branches default to switching the existing branch; remote selections default
to creating a branch with the remote branch's name and automatic tracking. Tag and
commit selections default to creating a branch and remember that checkbox choice.
New branch names are suggested from the reference or short revision. Editing the
remote-derived name disables automatic tracking. Track has distinct unchecked,
checked and mixed states; tracking controls require a remote and new branch.

The backend verifies the revision as a commit and validates new branch names before
mutation. Existing branches require Override; a tag sharing the new branch's name
produces Continue/Abort. Local branch checkout attaches HEAD. Tag, commit and remote
checkout without a new branch detach HEAD. Force and Merge are passed to Git.
Options errors keep the controls and entered name available. Production checkout
hands captured options to shared native progress. Every attempt refreshes open
status/log views; a successful result closes the options after acknowledgement.

App and Finder Switch commands, the status branch link, and the log revision
checkout action share this native dialog. A log checkout preselects its exact
commit, while retaining the repository access lease even if the workspace changes.
The reference browse sheet searches branch names; the commit chooser searches the
latest 200 revisions across branches. These are partial replacements for upstream
Browse References and selection-mode Log, rather than complete chooser ports.

## Verification

Seven real Git integration tests cover attaching a local branch while retaining
mixed index/worktree edits, annotated tags, detached commits, branch creation,
automatic/explicit/no remote tracking, hierarchical remote names, existing branch
and tag conflicts, invalid names/revisions, dirty checkout rejection, explicit
force, and merge checkout leaving conflict stages and markers. The historical suite at that checkpoint
had 53 passing tests; this is not a current full-suite claim.

Native QA created `native-switch-qa` on a disposable repository, chose `main` in
the reference browse sheet, and switched back. Index and worktree patches matched
byte-for-byte before and after both operations. The branch name and new-branch /
override enablement were inspected. `site/assets/switch-checkout.png` is a capture
of the actual native dialog; no mockup or synthetic image was used.

## Remaining differences

- Complete Browse References tree, tag/ref categories, filtering and context menus.
- Selection-mode Log with graph, pagination, all revision controls and history combo.
- Native UI verification of remote three-state tracking, tag warning/abort, force,
  merge conflict recovery and the log/Finder entry points; backend tests cover their
  checkout effects, but do not establish native UI parity.
- Resize/minimum-size, light appearance, keyboard navigation and accessibility QA.
- Physical shared progress/cancellation, submodule checkout options, hooks and
  interactive prompts.
- Broader preference/state persistence and detached/unborn repository scenarios.

The dialog and its source files remain partial in the inventory. This is not full
upstream parity or App Store readiness.

## Shared options and recovery result

Regular Switch/Checkout now owns the same native result as express RefLog Switch
and Branch creation. Read-only validation catches dialog errors before presenting;
Core repeats validation when executing. Captured target/revision, Create New
Branch/name, force, merge, tracking, override and accepted cross-name intent survive
later edits and Retry. The name-conflict Continue uses the submitted draft; Abort
clears it. A fresh options controller prevents another entry point replacing a
pending draft. A presenter that cannot own its sheet cancels before Git mutation.
AppKit sheet-dismissal completion releases the options owner and resumes a
Branch creation handoff after detachment. Legacy no-presenter model callers retain
their inline behavior.

Success actions follow PerformSwitch order: Submodule Update when the working
`.gitmodules` exists (even without a gitlink), Merge previous branch when attached,
Pull when the new HEAD is attached, then Commit. A gitlink without `.gitmodules`
does not add Submodule Update. Failure offers Resolve after merge conflicts,
Stash Save when not merging, Retry, and Switch with merge when not merging.
Retry retains original options with the effective merge setting; it uses a fresh
cancellation token. Existing original icons and split action button remain.
A follow-up dispatch closes the result first and cannot repeat.

The result captures AutoCloseGitProgress at submission. Manual/no-options retain
success actions; no-errors closes successful results. Errors/cancellation remain
reviewable. ConfirmKillProcess asks the source Yes/No question, with Yes default;
No leaves the owned process running and Yes cancels its process group. Completion
while a question is pending defers automatic close; a late answer cannot cancel
completed work or repeat its close. Native close/Quit guards include the result,
chooser and warning states; closing invalidates late callbacks.

[Progress QA](qa/switch-progress-2026-10-08.json) records focused Core validation,
four-Git actual full-option execution and retry/cancellation effects, and regression
receivers for express Switch and Branch/Tag. Hidden hosting/controller checks do
not prove physical nested sheets, default buttons, Root factory routing, signing,
Finder activation or signed sandbox acceptance. The existing Switch screenshot
predates shared result ownership. Full Switch/application parity remains partial.
