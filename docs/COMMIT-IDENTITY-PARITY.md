# Commit identity preparation and SSH signing

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
The source boundaries are `CAppUtils::CheckUserData/Commit` in
`src/TortoiseProc/AppUtils.cpp:3039–3069`, the author fields in `CommitDlg.cpp`,
`GetUserName/GetUserEmail/GetCommitterName/GetCommitterEmail` and the shared Git
askpass environment in `src/Git/Git.cpp`.

## Identity before Commit preparation

The source checks all four explicit author/committer values before constructing
Commit and before StartCommitHook. Missing identity offers Yes/No, opens Git
Settings on Yes, and reads the values again after Settings returns. No abandons
that Commit request. Git's synthesized login/host identity is not a configured
identity for this source check.

The native common Commit preparation boundary performs that read before status,
message templates and the Start hook. A disabled, uninitialized Commit host
owns the macOS question and Settings sheet; it has not loaded the file list or
message template. This boundary is shared by ordinary,
scoped/Finder/command-line and direct replay Commit consumers. Captured repository
access and preferences remain authoritative. Settings starts on Git in an
independent property-sheet transaction; returning from it does not certify the
identity. An unchanged incomplete identity repeats the question. A configuration
read error remains a retryable preparation error rather than running the hook.

The reader follows nonempty author/committer environment overrides, then explicit
author/committer configuration, then user.name/user.email. It retains the pinned
GetCommitterEmail use of GIT_AUTHOR_EMAIL for this UI preflight. Actual Git
subprocesses continue to receive Git's own ordinary environment semantics.
Ordinary Set author seeding uses the same effective author lookup; explicit
in-progress author edits and replay attribution retain their separate ownership.

The native question and Git Settings child belong to the captured Commit owner.
Cancellation/forced close rejects late answers and metadata, retires the owned
Settings transaction and keeps pending-work/Quit accounting until the reader and
actual native sheet release have completed. Reopening settings never switches the
captured request to a newly selected repository. Repair itself changes only the
configuration explicitly accepted in Settings; it stages no files and creates no
commit. Existing Commit choices, message/issue presets and paths are retained. Initial
checkbox observers cannot start author/date/amend reads before the gate. Captured
author/date installation values also fence delayed observers after Settings; a
later deliberate toggle still reads the ordinary default.

## SSH-format signing prompts

The source supplies SSH askpass in the shared Git environment. Native transport
commands already supplied the helper, but local signing commands previously did
not. Signing-capable Git commands now receive the existing bundled OpenSSH
askpass alias too. This covers commit/commit-tree, tag, merge, rebase, cherry-pick,
revert and am; Pull already inherits transport authentication. Actual signing
continues to be selected by Git configuration/options.

Transport authentication classification remains independent because it also
controls remote certificate handling. Signing does not create a remote
certificate exchange or install a Git username/password helper. Existing
SSH_ASKPASS, explicit SSH_ASKPASS_REQUIRE choices, the headless disable flag and
the private agent's dedicated key-loading helper keep their precedence. No login
agent, signing key or signing configuration is changed by opening Commit.
The secure helper supplies a response through its existing private pipe; the
owning Git operation retains cancellation and descendant cleanup. GPG pinentry,
external agents, hardware devices and arbitrary script UI retain their existing
configured behavior.

## Validation and remaining acceptance

The grouped checkpoint passed 11 distinct focused Core tests; the actual encrypted
SSH signing test also passed with bundled Git. Eighteen native case/engine checks
passed across Apple and bundled Git, including real private Git Settings edits,
Start-hook ordering, preset preservation, refresh, author controls and metadata
cancellation. Focused repairs addressed initial observer ordering and fixture
assumptions; all 24 owned receivers, including failed attempts, were reaped.
The Debug app builds passed, with existing toolchain/concurrency diagnostics.

[Recorded evidence](qa/commit-preparation-family-2026-10-20.json) retains the actual
failures, repair/check scope and light/dark captures. These are focused local
results; the full Core/native suites and current hosted CI were not certified.

Physical keyboard/VoiceOver behavior, every caller/layout, signed Settings grants,
real signing-agent/pinentry/security-key UI and signed App Store/Finder execution
remain separate acceptance. This is a connected Commit preparation/execution
family, not certification of the full Commit dialog or port.
