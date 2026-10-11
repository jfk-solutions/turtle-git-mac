# First Start Wizard — implementation in progress

Reference: pinned FirstStartWizard and its Language/Start/Git/User/Authentication
pages at `7338078f8ddd924b8cddee35f512f2286072136d`.

The native wizard uses the source five-stage order, page titles, Back/Next/Finish
and Cancel. General's Re-run First Start Wizard and the application menu reuse
one wizard window. The header uses the original turtle artwork. Language offers
only the installed English translation. Welcome explains the setup and links to
this fork's documentation. Git uses the shared native engine/path/Extra PATH
model, Browse and Check now. Next checks Git even if unchanged, saves the engine
and creates a configuration reader using that engine. AppStore Git stays bundled.
Windows Cygwin/MSYS compatibility hacks do not apply to the native Git runtime.

User information loads ordinary effective configuration, without replacing it
with process author-identity overrides. Its Don't store checkbox gates only
name/email writes. Next trims and validates both fields, then writes only these
two global keys. Other keys, includes, scoped credentials and repository-local
configuration remain untouched. Sequential failures report the key and possible
earlier writes. Saved earlier steps remain saved if Cancel ends a later step,
matching source wizard behavior. Back preserves current fields when the engine
is unchanged; changing engines refreshes the configuration reader.

Authentication uses OpenSSH, with existing SSH config/agent/remote key-file
behavior. HTTP helpers are discovered in Git's execution directory and PATH;
None plus installed osxkeychain/manager/manager-core/cache/store choices appear.
The existing effective helper is selected. Multiple, URL-specific or custom
helpers switch the page to a preserved advanced state, preventing simplification
from destroying existing configuration. Don't store skips the global helper
write. None removes only the unscoped global helper key (not URL-specific keys).
Finish saves the selected helper and records FirstStartComplete.

Global/XDG folders use the existing configuration permission store and owned
native authorization sheets. Closing fences pending chooser/read callbacks.
Active Next/Finish work guards close and application termination; forced closure
lets already-authorized writes finish while suppressing late navigation/finish.

The wizard opens once per process on startup until Finish records completion.
Cancel leaves setup available next launch. Documentation preview bundles and
XCTest hosts skip automatic presentation. Manual re-run remains available. Source refresh/localization
installation, key-generation workflow, Advanced credential dialog and Create
Library's macOS equivalent remain open. The latter controls are not shown as
inactive implementations. Full source page sizes/layout/focus and keyboard,
light/dark, helper discovery, global include/XDG precedence, Next/Back/Cancel,
partial failure, permission/read/close/quit ownership and signed sandbox checks
remain in the grouped General/Wizard validation. The earlier Settings/Tools
passing checkpoint does not cover this continuation. Inventory remains unchanged;
no dialog is newly certified.

## Grouped General/Updates/Wizard checkpoint — 2026-10-11

Debug Xcode build exited 0. The focused GeneralSetupBatchTests, GitRuntimeSSHTests
and GitConfigurationTests group passed: 13 tests, zero failures, 3.018 seconds.
Coverage includes selective identity saves, preservation of includes/scoped
credentials, validation before writes, idempotent helper clearing, engine
preference persistence, PATH validation/precedence and App Store isolation,
version/prerelease ordering, malformed tags, feed filtering and unexpected links.
No app was launched and no live release request was tested. Xcode emitted existing
warnings and six unusual SwiftCompile diagnostics reporting exit code 0 with no
output; this is not a clean diagnostics claim. Logs and remaining acceptance are
in `qa/general-setup-batch-2026-10-11.json`. Native visual/keyboard/ownership, live
network, bookmark renewal and signed sandbox acceptance remain open. This
checkpoint supersedes the uncompiled/untested statements above. Inventory is
unchanged; no dialog is newly certified.

## Advanced credential continuation

Advanced configuration now opens the native Credential page as an owned wizard
sheet, blocks navigation until closed, and reloads helper choices without
replacing identity fields. See CREDENTIAL-SETTINGS-PARITY.md. This continuation
is uncompiled and untested and is outside the preceding General/setup checkpoint.
Native SSH key generation and the rest of the authentication-section validation
remain pending.
