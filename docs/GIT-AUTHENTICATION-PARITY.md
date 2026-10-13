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
