# Reviewing an SMTP server certificate

When Send Mail cannot validate the certificate presented by an SMTP server,
**Certificate verification failed!** shows the server hostname, the validation
error, Common Name, Issuer and SHA-1/SHA-256 fingerprints. **Cancel** is the default
button. Cancelling rejects this connection before authentication or message upload.

Choose **Open certificate** to inspect the public certificate in macOS's native
certificate viewer or its selectable Text page. Trust editing is disabled.
**Copy fingerprints** copies both named fingerprints. **Export…** saves the exact
public certificate as DER (.cer) or PEM (.pem), using a native Save panel. This
neither accepts the connection nor changes Keychain trust. An accepted export
finishes before its owning inspector and certificate decision are released.

After checking the server with its administrator, **Accept certificate** permits
this connection. The exception is temporary: the same Send Mail workflow can
reuse it only for exactly the same hostname, port and certificate bytes. A changed
certificate, another host or another port requires a new decision. The exception
is not saved in Settings, Git configuration or Keychain and is not shared with
other Send Mail windows.

The review applies to configured SMTP and direct SMTP, including a STARTTLS
upgrade on the connection that presented the certificate. Authentication and
message content wait for the decision. Encryption **None** retains opportunistic
STARTTLS when advertised and can use plain SMTP when it is absent. Select
**STARTTLS** or **TLS** in Email settings when encryption is required.

Cancel or closing the progress window aborts an active review and its owned
inspector/picker. A late acceptance cannot resume a cancelled submission. A save
already accepted is allowed to finish while closing waits. Quit also waits for
owned transport and window cleanup. A lost final server reply may mean a message
was accepted; TurtleGit reports uncertain delivery and does not automatically
resend it.

This SMTP decision is separate from [Git authentication](GIT-AUTHENTICATION.md)
and [SVN certificate authentication](SVN-AUTHENTICATION.md). The existing
[certificate inspector screenshots](CERTIFICATE-INSPECTOR.md) show the SVN helper;
they are not captures of the SMTP review window.
