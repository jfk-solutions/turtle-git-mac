# SSH preparation at Git transport boundaries

Pinned upstream `7338078f8ddd924b8cddee35f512f2286072136d`:
`AppUtils.cpp::DoFetch`, `DoPull`, `DoPush` and `LaunchPAgent`.
Source Fetch All loads every configured remote key before one fetch invocation;
Push loads each remote's key immediately before that remote's push. The return
from source LaunchPAgent is ignored by these callers. Complete native error and
retry decisions remain a coordinator responsibility, not proven source parity.

Core Fetch, Fetch for Rebase, Pull, Push and remote-branch lookup now accept an
optional awaited `SSHTransportPreparation` callback. Existing callers use nil
and retain normal Git environment behavior. This checkpoint does not wire native
auto-load controls or present the new key/passphrase dialogs during transport.

Fetch validates its options, then supplies either the selected destination or
all remote names once before running Git. Fetch for Rebase forwards the callback
through its selected-branch fetch; target capture and recovery reads do not
re-run preparation. Pull supplies its destination before the transport command.
Branch lookup supplies its destination before ls-remote. Push validates the plan,
retains its existing saved-config effects, then prepares one remote before its
first push. All-branches plus tags shares that session for both commands.

The callback can suspend for native grant or passphrase decisions and reenter
the repository actor for settings reads. It returns an owned `SSHAgentSession`
or nil. A returned session is retained through the command, including both Push
branches/tags invocations and error/cancellation paths. Git receives its private
socket and an empty `SSH_AGENT_PID`; an inherited login-agent PID is not paired
with that socket. A coordinator may retain a shared session to accumulate keys,
and must eventually close/release it. File grants must remain held during key
loading. No credentials are added to Git argv or environment.

Preparation receives the caller's cancellation token, or an owned token when
none was supplied. Cancellation is checked before and after awaiting the response
so a late response cannot launch Git. Preparation errors abort the current
transport. Push wraps such failures with prior completed destinations and stops
later remotes; successful earlier pushes and prior saved config are retained.
This hook behavior is not a claim that native error decisions exactly match the
source callers' ignored Pageant return value.

Six new tests use a real private agent, generated fixture key and a controlled
Git wrapper. The wrapper refuses to query any agent unless its socket is inside
the fixture, verifies the public fixture identity before executing real Git, and
asserts an inherited sentinel PID is cleared. Local repositories verify Fetch,
Fetch for Rebase, Pull and branch lookup, Fetch All's one callback, Push's ordered
partial success, shared branches/tags lifetime, validation/pre-cancel/late-cancel,
and live Git helper/child plus agent reaping. No SSH server is contacted: local
Git effects and Unix-agent access prove the preparation channel, not network
SSH authentication. Nil-callback Fetch/Pull/Push regression tests also run.

Remaining: native auto-load controls/preferences, owned prompt/coordinator wiring,
bookmark loading and retry/cancel policy, all other SSH consumers, bundled
OpenSSH, Keychain, host-key/password prompts, signed App Store/Finder and real
network authentication. Concurrent config/ref changes across suspended preparation
and complete source failure equivalence remain unverified.
