# Commit and Push continuation

Implementation continuation, 2026-10-23. Grouped Core/native validation passes with the recorded test-constructor repair. This is a connected Commit completion workflow, not a claim that the whole Commit or Push family is complete.

The pinned source is TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`. `src/TortoiseProc/CommitDlg.cpp:553–567` resolves the current branch and `GetRemotePushBranch`, uses the Push dialog when requested or either mapping is empty, and otherwise invokes `CAppUtils::DoPush` directly. Its footer completion invokes that helper with the submitted amend choice; the progress-result Push action remains the ordinary Push dialog. `src/Git/Git.cpp:867–898` resolves `branch.<name>.pushremote`, then `remote.pushdefault`, then `branch.<name>.remote`. It takes `pushbranch` verbatim, including Gerrit refs, otherwise applies `StripRefName` to `merge`. There is no sole-remote inference. Detached HEAD returns early in `GetCurrentBranchFromFile`.

The native successful-attempt callback now carries footer/progress origin and the captured submitted amend flag. A normal footer Commit & Push resolves the explicit mapping after Commit completion. A mapped branch opens the existing native Push progress/result directly; amend, missing mapping and progress-result Push open the normal Push dialog. Detached HEAD does not start a push or invent a branch. The ordinary Push dialog's existing defaults and sole-remote suggestion remain separate.

Direct continuation captures the current short branch, remote and destination, and enables no force, force-with-lease, upstream, tags, all-branch, save-mapping or recursive-submodule options. A source mapping to `.` or another nonnamed target uses the existing owned arbitrary-URL executor path. No transport command is constructed or executed by a second generic runner.

The existing Push workflow owns access validation, SSH/authentication/certificate preparation, client hooks, streamed output, real rejection/error/cancellation status, post-actions and pending-operation drain. A retained Push owner presents a standalone progress window while its normal form stays hidden. The result exists before submission validation and hooks so their errors remain reviewable. Mapping read failures expose the ordinary native error/retry form, a native diagnostic adaptation instead of silently ignoring a failed read. Direct submissions do not rewrite the ordinary Push dialog's saved option/history draft. Ordinary Push post-hook recovery behavior remains unchanged; direct post-hook warnings are appended even after streamed output, retain successful transport and post-actions, and inhibit automatic result dismissal.

The Commit owner may close before continuation starts; the captured repository, preference store and access lease belong to the accepted Push owner until real callbacks drain. Mapping and transport cancellation use existing owned cancellation tokens/process groups. Completion refreshes the original repository's logs/status without retargeting to a later workspace root.

The local checkpoint covers private bare remotes, mapping precedence, raw destinations, local-dot mapping, actual footer/progress/amend routing, missing mappings, detached HEAD resolution, failure, cancellation and lifetime. Physical remote authentication and every upstream transport combination remain separate acceptance claims.

This is a partial continuation of `IDD_PUSH`; its static control mappings
and full layout/behavior acceptance remain separate. The
[shared checkpoint](qa/commit-scope-report-push-2026-10-23.json) records actual results.

## Grouped validation checkpoint

The [dated shared checkpoint](qa/commit-scope-report-push-2026-10-23.json) records
22 relevant Core methods and six native case/engine pairs passing. The first Core
attempt stopped during new-test compilation because a fixture constructor omitted
a required argument; supplying it repairs the test without a production change.
The Debug app build exited zero with 29 generic “failed with exit code 0”
diagnostics. Native scenarios passed on their first execution; all six receivers
were reaped and independently confirmed absent. The two scope receivers each
emitted two AppKit table-delegate reentrancy warnings. A bounded static review
identified shared row-decoration callbacks as a plausible cause; no runtime stack
was captured, and a related native-list follow-up remains open. This checkpoint
does not certify physical interaction, signed execution, current hosted integration
or whole-dialog parity.
