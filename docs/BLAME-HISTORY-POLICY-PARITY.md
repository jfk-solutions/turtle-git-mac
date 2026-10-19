# Blame embedded history action policy

This connected partial review follows pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseGitBlame/LogListBlameAction.cpp::hideUnimplementedCommands`,
`GitLogListBase.cpp::ContextMenuAction`, `OnNMDblclkLoglist` and
`PreTranslateMessage`. It covers the embedded history list, not the separate
source-line popup or every Blame state.

The native list now consumes the shared `.blame` command policy rather than
maintaining an unrelated implicit subset. Mask changes retire captured native
callbacks, including a change away and back. Busy/child and closed-owner gates,
canonical pinned revisions, original icons and one-shot per-item dispatch remain.
Normal Show log children retain the ordinary Log policy.

Blame history metadata records working-tree availability and current HEAD in its
owned, cancellable snapshot read. Checkout is omitted for HEAD and bare
repositories. The source unified-parent action requires a working tree; historical
Compare with previous remains available in bare repositories. Actual operations
still use their existing fresh preparation, permission and validation paths;
these displayed gates are a captured snapshot, not a filesystem authorization.

Parent actions follow source order: Blame previous, unified Diff, Compare with
previous. Repo-browser, Checkout, Branch, Tag and Export retain source order.
Clipboard actions use the source submenu rather than two additional root copies.
Filtered menus remove empty leading/trailing/doubled separators. Source-line
clipboard commands are separate and retain their own existing layout.

Double-click and Return in the embedded list now use `DiffByDoubleClickInLog`.
When disabled they do not launch Show log. When enabled they prepare the selected
revision's first parent using the existing owned reader, retain the chosen
alternative-tool flag, and compare that parent after checking the original owner,
policy and selection. The source default comparison entry and first parent are
emphasized with native bold menu text. Show log remains an explicit menu action.

The focused native fixture covers actual working/bare repositories and native
menus, private preference off/on, parent/default ordering, captured selection,
policy retirement, repeated dispatch refusal and HEAD/index/input invariants.
The retained Blame fixture continues its existing metadata, source controls,
clipboard and child-operation assertions, using a non-HEAD revision for Checkout
and the source clipboard submenu. Actual results appear in the parent batch QA;
fixture existence is not a pass.

Physical double-click/keyboard menu gestures, VoiceOver tracking, refreshed remote
writers between presentation and execution, all source popup variants, minimum-OS/
Intel and signed App Store/Finder acceptance remain open. No whole-dialog or
whole-application certification is inferred.

Actual grouped build/check outcomes: [history action batch evidence](qa/history-actions-2026-10-18.json).

The October 20 [hosted readiness continuation](qa/hosted-blame-policy-2026-10-20.json)
records the older hosted bare-menu failure after a successful 2,237-method Core
run (two skipped). The fixture now awaits the actual native/coordinator rows,
exact native/model selection and prepared parent cache before evaluating the
unchanged policy assertion. Both focused local Git cases pass with owned
receivers reaped. A scheduling race is inferred; its historical timing was not
reproduced, and a complete new hosted pass remains required.
