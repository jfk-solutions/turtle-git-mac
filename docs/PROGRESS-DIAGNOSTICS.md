# Command identity and progress failures

Git options before the command no longer turn an error heading into `git -c`.
The shared command identity also routes replay output and credential helpers by
the actual operation, rather than a branch name or configuration value.

Progress dialogs retain their captured output limit. If a later preparation
command fails without streaming, its diagnostic is displayed alongside earlier
output, with space reserved for the operation and exit status. An already
streamed failure adds its completion status without appending the full raw output
again. Raw command results remain available to recovery decisions, including
Push rejection actions. Cancellation retains partial output and owned process
cleanup. Native progress Copy All and redraws preserve Unicode spelling.

## Source comparison

Pinned TortoiseGit revision: `7338078f8ddd924b8cddee35f512f2286072136d`.
`src/TortoiseProc/ProgressDlg.cpp` (blob
`557988a1303dc86b11c9c74d29be4797aa7e6090`) and
`src/TortoiseProc/GitCliOutputParser.cpp` (blob
`719cd542dbb77314dedca6f28f6ad1c29eb43421`) provide the progress/output context.
The global-option grammar follows the bundled Git 2.55.0 `git.c::handle_options`.
The port uses native progress windows and typed Swift failures; this is a
behavioral continuation, not complete Progress dialog certification.

## Verification and remaining work

The connected batch covers local command progress and Clone, Fetch/Pull, Push,
Merge and Format Patch error paths. The [dated QA record](qa/progress-diagnostic-family-2026-10-17.json) records
26 passing Core cases and 12 native engine/family checks, including the corrected
compiler/capture/Push fixture attempts. Physical keyboard/pointer/VoiceOver behavior, authenticated network failures,
signed sandbox execution and complete source-dialog parity remain open.
Unknown Git options stop command identification rather than guessing their values.
Generic application errors still use the caller's fallback preferences; the
captured-policy bridge specifically handles Git failures and Git cancellation.

Native Stash failure captures: [light](site/assets/progress-diagnostic-light.png)
and [dark](site/assets/progress-diagnostic-dark.png).
