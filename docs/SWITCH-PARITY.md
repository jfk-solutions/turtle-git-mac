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
Errors keep the controls and entered name available. Successful operations close
the dialog and refresh any open status/log windows for that repository.

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
force, and merge checkout leaving conflict stages and markers. The complete suite
has 53 passing tests.

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
- Progress/cancellation, submodule checkout options, hooks and interactive prompts.
- Broader preference/state persistence and detached/unborn repository scenarios.

The dialog and its source files remain partial in the inventory. This is not full
upstream parity or App Store readiness.
