# SVN authentication

The bundled SVN runtime opens native prompts when an SVN operation needs a
username/password, certificate passphrase, server-certificate decision or client
certificate. Explicit custom askpass configurations keep their own behavior.

The credential window shows the authentication realm, username and a masked
password. Save authentication is available only when SVN allows caching.
Cancel stops the prompt. The runtime uses Subversion's native providers; its
build requires macOS Keychain support and disables plaintext password storage.
Signed Keychain behavior remains a distribution acceptance check.

Certificate Check shows the server name, issuer, validity dates, separate SHA-1/SHA-256 fingerprints and
validation failures. Open certificate shows an owned read-only details window. Reject is the default; closing the window or pressing Escape
rejects. Choose temporary acceptance only for the current authentication attempt,
or permanent acceptance when that option is allowed by SVN. Compare certificate
details with the server information you trust before accepting.

For a client certificate, choose its local file. TurtleGit reads the chosen file
through the picker and gives the running SVN command a private temporary copy.
The original stays untouched, the copy is removed with the command, and that
filename is not cached for later operations. A password prompt may follow.

These prompts currently adapt the SVN callback metadata. Public TLS/server and signed/physical acceptance remain open. Older requests
without certificate bytes retain the reported SVN fingerprint and cannot open
the details viewer. Other Git/OpenSSH prompts
retain their existing behavior.
