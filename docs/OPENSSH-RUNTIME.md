# OpenSSH runtime preparation

The full port needs an app-owned SSH client and private-agent tools for sandboxed
Git transports. This build foundation does not yet embed them in the app or
change transport resolution. App Store SSH acceptance remains incomplete.

`Configuration/OpenSSHRuntime.json` pins OpenSSH 10.6p1 and OpenSSL 3.5.9,
publisher archive checksums, arm64/x86_64 slices and a macOS 13 deployment target.
The source checksums were compared with the
[OpenSSH release notice](https://www.openssh.org/txt/release-10.6) and
[OpenSSL downloads](https://mirror.openssl-library.org/source/).
This is checksum verification, not publisher PGP signature verification.

Build and audit on a Mac with Xcode command-line tools and Python 3:

```sh
python3 scripts/build-openssh-runtime.py
python3 scripts/validate-openssh-runtime.py build/openssh-runtime/OpenSSH
```

The five selected tools are ssh, ssh-agent, ssh-add, ssh-keygen and ssh-keyscan.
OpenSSL is statically linked; shared modules, dynamic engines and automatic
OpenSSL configuration loading are disabled. PAM, Kerberos, libedit and the
built-in FIDO provider are disabled in this preparatory build. PKCS#11 and
security-key helper processes, external providers and hardware keys are not
packaged or accepted. These are remaining requirements, not a claim of complete
TortoiseGit authentication parity.

The output retains original OpenSSH and OpenSSL licenses, complete pinned source
archives, the build script and pin configuration under Sources, and a provenance
manifest recording every retained file and binary hash, compiler and SDK.
The recorded reconstruction command builds from these retained archives.
OpenSSH license notices describe BSD and other permissive components; OpenSSL's
original Apache 2.0 text is retained. The application license remains unchanged.

The audit checks exact inventory and hashes, both architecture slices, minimum
OS and system-only dynamic dependencies. Its runtime fixture uses a private HOME
and foreground agent, generates disposable Ed25519/ECDSA/RSA keys, checks loading
and removal, and rejects an encrypted key with prompting disabled. It does not
use the login agent, contact an SSH server or launch the main application.
Runtime execution is on the host architecture; universal slices alone do not
prove Intel execution or macOS 13 compatibility.

The [local audit record](qa/openssh-runtime-foundation-2026-10-10.json) records
the fresh build, independent audit and five tamper rejections. Complete rebuilding
from the retained reconstruction package has not yet been exercised.

## Remaining integration and acceptance

- Embed and sign helpers with inherited App Store sandbox entitlements, updating
  post-sign provenance and verifying the containing app.
- Select the bundled SSH client for packaged Git without replacing explicit user
  SSH commands; retain operation-owned agent and identity security scopes.
- Exercise encrypted-key loading through the existing one-use askpass channel.
- Test actual authentication, host-key decisions, passwords, Keychain, connection
  failures, cancellation, both CPU architectures and signed app/Finder routes.
- Audit hardware-key/provider support and PuTTY-key conversion.

See [SSH agent parity](SSH-AGENT-PARITY.md) and
[distribution preparation](DISTRIBUTION.md). Successful standalone compilation
is not evidence of signed sandbox invocation or App Store submission readiness.
