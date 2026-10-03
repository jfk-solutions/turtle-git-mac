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
preference is remembered; bare repositories hide switch. Creating with switch
checked checks out the new branch immediately. A failed checkout keeps the created
branch and offers Retry checkout, with creation controls disabled to avoid creating
it twice. Cancel leaves that already-created branch intact.

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
The complete Swift suite has 63 passing tests.

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
- Progress/cancellation and recovery if description configuration fails after the
  branch was created; tests establish Git effects, not complete recovery parity.
- Full settings/size persistence and a broader supported Git-version matrix.

This dialog remains partial in the upstream inventory. It is not full parity or
an App Store-ready release.
