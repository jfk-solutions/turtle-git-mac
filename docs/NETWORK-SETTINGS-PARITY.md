# Network settings — implementation in progress

Reference: pinned SetProxyPage.cpp/.h and IDD_SETTINGSPROXY at
7338078f8ddd924b8cddee35f512f2286072136d.

The native Settings tree now includes Network with the original proxy.ico.
The layout follows the source Enable Proxy Server checkbox, Proxy Settings group
(address/port/username/password), spacing, and lower SSH group with editable
client path and Browse. Native additions provide automatic-client reset and a
version check so an executable file can be checked before it is saved. Shared
property-sheet Apply/Cancel owns the draft; cached hidden pages apply through the
owning Settings window. Repository changes unregister the old Network model.

Proxy configuration loads Git's effective http.proxy, including existing local
precedence. Apply writes only the global http.proxy key; disabling removes that
global key, preserving repository/URL-specific settings and includes. Address
parsing handles supported HTTP/HTTPS/SOCKS schemes, optional embedded ports,
userinfo escaping and IPv6 syntax through URLComponents. Separate port values
must be 1–65535, or blank/zero for an unspecified port. Username/password remain
separate native fields; malformed effective URLs allow entry of a replacement
rather than silently rewriting the imported value. Git keeps the configured
proxy URL, including its authentication fields, in its ordinary configuration.
Write failures suppress command arguments and Git diagnostics that might expose
proxy credentials and report the key instead.

Source registry draft retention is adapted to nonsecret preferences plus a
Keychain password cache. Disabling a proxy retains address/port/username and the
password for later re-enabling. Passwords are not duplicated into UserDefaults.
Cache/preferences precede the global Git write, matching source-ordered partial
save behavior; a later failure can leave earlier draft retention saved. Ordinary
Cancel restores only unsaved UI fields. Proxy saves precede SSH preference saves.

Custom SSH selection uses executable-file security bookmarks, retained grants,
OpenSSH -V validation, an absolute executable path and a ten-second bounded
check. No shell parses that path. Empty selection means automatic OpenSSH.
GitRepository injects the selected client through GIT_SSH/GIT_SSH_VARIANT only
when process GIT_SSH/GIT_SSH_COMMAND are absent; Git's core.sshCommand and per-
operation overrides retain precedence. An unavailable saved client fails SSH
rather than falling back to a different client; ordinary Git configuration
commands remain able to repair it. General's environment viewer reflects the
same selection. App Store builds ignore custom clients and retain bundled
OpenSSH, with custom selection/check/browse disabled.

Owned global/XDG authorization and Browse panels use cancellation/generation
fences and one-shot permission responses. Hiding or retiring the page cancels
pending reads/checks and closes its panels. Already-authorized save sequences
can finish after forced closure. Active saves guard page switches, window
closure and application termination. Normal version checks are canceled on
retirement; Apply checks are bounded even if the chosen client hangs.

This substantial backend/UI/runtime batch is **uncompiled and untested**.
Validation remains deferred to the combined Network/Finder-settings section
boundary. The preceding authentication checkpoint does not cover it. Outstanding
checks include escaping/scheme/IPv6/port edge cases, live scoped proxy writes,
Keychain retention/failures, SSH precedence and unavailable/moved bookmarks,
version timeout/cancellation, cached Apply/Cancel/partial failures, native layout/
keyboard/theme and owned panels, Finder runtime boundaries and signed sandbox
execution. Source PuTTY/plink client behavior is replaced by native OpenSSH;
non-OpenSSH executable variants and key conversion remain open. No dialog is
newly certified and the whole port remains incomplete.
