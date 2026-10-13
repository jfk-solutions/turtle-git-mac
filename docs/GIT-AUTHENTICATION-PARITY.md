# Git CLI authentication prompt parity

Pinned reference: `7338078f8ddd924b8cddee35f512f2286072136d`,
`src/SshAskPass/SshAskPass.cpp` and `SshAskPass.rc:IDD_ASK_PASSWORD`.

The source helper shows the supplied prompt, a response field and OK/Cancel,
returns a response through stdout and closes after that single exchange. It
masks prompts containing “pass”; the macOS adaptation exposes recognized Git
username requests and masks unfamiliar requests as well as passwords. It uses
native secure/plain fields, Return/Escape, selectable request text, bounded
single-line UTF-8 responses, field clearing and the original turtle icon. Long
requests increase initial window height within a bound; the window is resizable.
The source CLI helper has no Save authentication control.

The bundled tool has SDK-only linkage, no credential persistence, and is
relocated with runtime code into Contents/MacOS, keeping its helper alias and
source/hash provenance. AppStore signing uses inherited helper entitlements.
GitRepository installs it only for potential authentication commands, after
honoring environment, command-line and effective core.askPass choices. Queries
retain the caller’s environment overrides and cancellation. Git invokes the
helper by its direct executable path, including spaces/apostrophes; it is not a
shell-quoted command. Existing configured credential helpers still run first.

Eight unique focused Core cases passed after repairing one real Git helper-path
case, and six grouped native cases passed across system and bundled Git. Debug
and unsigned AppStore compilation passed. The AppStore bundle audit verified the
universal macOS 13 helper and the 203-item production runtime layout. See
[dated QA](qa/git-askpass-2026-10-13.json). Physical prompts, parent-operation cancellation of
an actual displayed helper, signed inherited-sandbox/Keychain/helper behavior,
public-server authentication, long-request/accessibility acceptance and full
HTTP/SSH/certificate dialog parity remain unverified. No generic authentication
family is certified complete from this CLI helper.

## Displayed helper checkpoint — 2026-10-13

An isolated ad hoc preview of the real Debug helper displayed the fixture password
request in light and dark modes, with original artwork and native secure field,
OK/Cancel and initial focus. Return delivered exactly one fixture response to
the pipe and exited; Escape returned no data and exited. A separate Core-owned
Git wrapper displayed the helper, then cancellation reaped the wrapper/helper
and completed the receiver. All owned PIDs were independently absent afterward.

Current-process PNG capture is available only in documentation-preview Debug
helper windows via Command-Option-Shift-S. Normal helpers and Release builds do
not expose that action. See [dated evidence](qa/git-askpass-display-2026-10-13.json).
This checkpoint resolves the observed standalone layout/theme/Return/Escape and
displayed parent-cancellation scenarios. Plain username/long requests, full
keyboard/VoiceOver, live server and signed inherited-sandbox acceptance remain
unverified. Earlier pending entries describe the earlier checkpoint.
