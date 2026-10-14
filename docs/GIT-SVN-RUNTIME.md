# Private Git SVN runtime

The pinned Git 2.55.0 runtime was built with `NO_PERL=YesPlease`, so its git-svn
entry was a failure stub. `build-git-svn-runtime.py` now builds a private
component from checksum-verified sources. It does not install into macOS or
Homebrew directories, and users do not need a system Perl/Subversion installation
when they select the bundled Git.

Pins are recorded in `Configuration/GitSVNRuntime.json`: Perl 5.44.0,
Subversion 1.14.5 LTS, APR 1.7.6, APR-util 1.6.5, Serf 1.3.10 and the same
OpenSSL 3.5.9 source used by the existing OpenSSH runtime. SCons 4.8.1 is a pinned
build-only tool. Official release/checksum sources are recorded beside every
archive; see [Perl's release announcement](https://www.nntp.perl.org/group/perl.perl5.porters/2026/07/msg271063.html),
[Subversion LTS downloads](https://subversion.apache.org/download/),
[APR downloads](https://apr.apache.org/download.cgi) and
[Serf distributions](https://downloads.apache.org/serf/).

Each CPU has its own private interpreter, core/XS modules and native libraries;
the dispatcher is universal arm64/x86_64. This avoids merging architecture-
specific Perl configuration files. macOS deployment is capped at 13.0. The
component includes generated release Perl bindings, internal LZ4/utf8proc,
file/SVN/Serf transports, system SQLite/Expat and statically linked OpenSSL with
module/config auto-loading disabled. TLS uses the standard `/etc/ssl` certificate
location; real TLS/trust acceptance remains separate from local validation.

The C dispatcher resolves its own location, chooses the matching payload and
executes the bundled interpreter with unchanged argument boundaries. It selects
bundled Git modules and clears interpreter-code injection options. Git's template
and exec paths still come from the existing containing-app runtime environment.
The generated git-svn script adapts `TURTLEGIT_SVN_CONFIG_DIR` to its existing
Subversion configuration variable because Ignore commands do not accept the
config-dir CLI option. App Store helpers receive an application-support config
path; ordinary desktop users retain their default configuration unless they
explicitly provide this environment value. No HOME variable is repurposed.

Native dependencies are rewritten to contained loader-relative paths and receive
ad-hoc signatures for development execution. The archive and installed-component
audits verify hashes, aliases, per-slice deployment targets and dependencies.
Validation hides the original build-prefix directories while exercising a
disposable `file://` SVN repository, so installed-path fallbacks cannot silently
make a broken relocated payload pass. Main Git validation recognizes the private
thin CPU buckets while retaining its universal-main-binary checks.

Install the verified component with `install-git-svn-runtime.py`. It stages narrow
payload/launcher/license replacements with rollback and updates the prepared
Git manifest. `build-git-runtime.py` includes this step. Xcode embedding requires
Git LFS and SVN components; executable helpers receive sandbox inheritance and
hardened-runtime signing, while libraries/bundles receive library signatures
without executable sandbox entitlements. Unsigned/ad-hoc validation is not
evidence of Developer ID/App Store acceptance.

Source archives, notices, launcher and reconstruction scripts accompany the
component. The private build cache fingerprints pins, SDK and compiler, with
per-component recipe stamps; rebuilding a changed Perl recipe starts from fresh
source to avoid mixed generated headers/objects. Intel Perl module linker flags
explicitly select x86_64. Universal interpreter builds require Apple Silicon and
a working Intel execution environment; CI prepares this component in a standard
Apple Silicon job and transfers a tar archive preserving aliases/permissions to
the existing Intel test job. See the [official runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

Still open: signed helper/library validation and inherited bookmarks, actual
App Store config/Keychain/trust behavior, authenticated HTTP/SVN/SSH acceptance,
minimum-system execution, complete security-advisory/license review of the new
distribution and a fresh remote CI run. The component is development work toward
the complete port, not a certified distributable release.

Local validation on 2026-10-12 audited 179 component Mach-O files, both CPU
payloads, deployment/loader paths and hashes, then exercised actual clone, fetch,
DCommit and both Ignore commands on a disposable file:// SVN repository with
original build-prefix directories unavailable. The installed main Git package
also passed its existing local workflows and Git LFS provenance checks; the
Debug app contains the new component manifest. These results do not establish
signed Store acceptance, public authenticated transport or a successful remote
CI run. Logs and exact scope are in
[the dated record](qa/svn-batch-2026-10-12.json).


## Hosted runtime cache dependency repair — October 14, 2026

The complete Git SVN cache now uses the shared immutable runtime-key recipe,
including the native SVN prompt adapter. Changing credentials/certificate callback
code must invalidate the packaged Perl modules and reconstruction manifest; a
previous cache key omitted that input even though the validator rejects an old
adapter hash. Restored and freshly built payloads still run the same complete
audit before saving or transferring to the Intel build job.

The native build workspace has a separate exact cache, keyed by runner/compiler/
SDK build/paths, checkout path, both pin manifests, builder and verified-download
recipe. The checkout path keeps prefix-bound native work separate after a repository
rename or checkout move. Prompt-only
edits reuse the existing architecture/component stamps and native prefixes while
repackaging the Perl adapter and launcher. Component build recipes and flags are
still checked by the builder. Native work is saved only after a newly packaged
payload passes its final audit; a full payload hit with no work tree does not
attempt to save a missing tree. No prefix cache fallback or validator exception
is introduced. This improves future hosted rebuilds after the native-work cache
has been populated; a cold cache still compiles its native dependencies.

The six cache-contract checks passed after the final key inputs were captured.
No app/Core/native UI checks were repeated. See [CI cache evidence](qa/svn-ci-cache-2026-10-14.json);
actual hosted warm/cold restore/build/save behavior awaits the next CI execution.
Native runtime behavior, full application integration and signed acceptance are
not proved by this workflow dependency change.
