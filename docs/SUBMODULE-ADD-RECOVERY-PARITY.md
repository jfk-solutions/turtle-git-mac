# Submodule Add recovery and mutation reporting

This is a partial audit of `IDD_SUBMODULE_ADD` and connected `IDD_GITPROGRESS` workflows.

The source reference is `src/TortoiseProc/Commands/SubmoduleCommand.cpp`,
`SubmoduleAddCommand::Execute`, pinned at
`7338078f8ddd924b8cddee35f512f2286072136d`. It runs Submodule Add, then saves the
selected SSH key in the new child's local remote configuration after successful
Git progress. The native counterpart uses the independent OpenSSH setting
`remote.origin.turtlegitsshkeyfile`; it preserves the source controls, Force/Branch
precedence, histories and scoped destination selection.

## Separate Add and configuration outcomes

Adding/staging a submodule and saving its child key are separate mutations. A
failed key write now reports that the submodule was added, retains its diagnostic,
and offers **Retry key configuration**. Retry validates the original superproject,
registered literal destination and captured child Git-directory identity, then
writes only the original local key setting. It neither repeats Submodule Add nor
opens a new private SSH agent. Changed checkout identity is rejected before write.
A missing receipt never falls back to re-adding an already-created module.

`SubmoduleAddOutcome` captures preparation/Add/key/completion phase, attempted,
added, configured and cancelled facts, output and optional immutable recovery
receipt. `SubmoduleAddExecutionFailure` retains that outcome and original error.
The legacy Core `addSubmodule` String/error API remains compatible. A Git Add exit
failure is reported as an attempted mutation without claiming that a valid module
was added; partial files/configuration may still need user review. Validation or
SSH preparation failure is not reported as an attempted Git mutation.

The native `onAttemptCompleted` callback publishes exactly once per attempt,
including failure, cancellation and forced owner retirement. It is independent of
the existing success-only `onAdded` callback. Root repository refresh uses actual
attempted mutations; success consumers retain their original contract. This avoids
hiding newly staged gitlinks or partial configuration behind a generic Add failure.

Operation counters retain actual work, repository/source/key grants and the
private coordinator until the process and completion unwind, including forced
window closure. Deferred application Quit and duplicate Retry cannot start another
operation. Cancel and close preserve the accepted options and original key path.
Native folder/key panels, passphrase children and cancellation alerts inherit
owner appearance and alpha before presentation so automated checks remain hidden.

## Focused coverage and remaining work

`Tests/TurtleGitCoreTests/SubmoduleAddRecoveryTests.swift` covers real local Add
followed by injected key-write failure, configuration-only recovery with unchanged
parent HEAD/index, cancellation before recovery and refusal of a replaced child's
Git directory. The private transport fixture uses an operation-owned agent and
local-only file-transport override.

`qa/submodule-add-recovery-native-2026-10-18.swift`, entry
`SubmoduleAddRecoveryVerification.verify()`, covers typed partial/success callbacks,
no repeated Add or agent creation during recovery, retained option/key identity,
deferred Quit, duplicate Retry, real owned key-write cancellation/forced close,
actual helper/agent cleanup and private native windows. Directly affected retained
coverage is Submodule Add input/history/panel acceptance and the Add sections of
the existing SSH coordinator receiver; its success-only callbacks and original
Git exit-code/bounded-output assertions remain applicable. The grouped checkpoint passed both Git engines for this native recovery case,
and the related Core tests passed. The evidence below records the initial missing
fixture Browse grant and its repair; native permission checks were preserved.

Real credential-bearing SSH servers, physical interactions, VoiceOver, signed
sandbox/Finder grants, older macOS/Intel and full upstream dialog visual/control
acceptance remain open. This native recovery behavior adapts the source's two-step
operation; source does not contain this native Retry workflow. It does not claim
whole-dialog or whole-app completion.

Grouped execution outcomes and repairs are recorded in
[batch evidence](qa/stash-submodule-workflows-2026-10-18.json).
