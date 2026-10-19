# Exact text in connected Git settings — October 19, 2026

Pinned source: `7338078f8ddd924b8cddee35f512f2286072136d`,
`SettingGitConfig.cpp:246–262`, `SettingGitCredential.cpp:224–232,718–800`
and `SetProxyPage.cpp:207–245`. The source marks field changes and compares
entered strings without Unicode canonical-equivalence folding. Its separate
credential field mask still determines which settings Apply writes.

## Connected behavior

Git identity fields, credential URLs/helpers/usernames, proxy fields and the
saved SSH path must distinguish entered Unicode spellings even when they look
the same. For example, an accented character can be one scalar or a letter plus
a combining accent. Swift's ordinary String equality treats these as equivalent;
it cannot determine whether these settings have changed or whether two Git
credential subsection names are the same.

This family uses exact UTF-8 comparisons for editable settings and captured
drafts. Credential entries retain their exact scope, origin, key, value and
value-presence flag. Grouping and stable row identity distinguish exact URL and
origin spellings; row identifiers encode the tuple rather than exposing a
canonically equivalent String identity. Display ordering keeps a deterministic
byte-level tie break. Save and Remove use the captured exact group and snapshot;
an external canonical-spelling-only change is still an external change.

Credential Apply retains its existing edited-field mask, helper/reset ordering,
implicit and repeated boolean forms, included origins and unknown keys. A
username-only edit does not replace helper entries. A URL copy leaves its source
rule intact. Empty optional fields and unchecked HTTP-path retain the previously
documented unset/inheritance behavior. Explicit Add New/Save, replacement
confirmation and shared Settings Apply/Cancel keep their distinct semantics.

Git on macOS can precompose command arguments when `core.precomposeunicode`
is enabled, including config text unrelated to filesystem names. These settings'
config invocations override it with `-c core.precomposeunicode=false` for that
invocation, preserving submitted key/value/file arguments. Git parses command
parameters before its config builtin's argument precomposition. The stored
preference and other Git operations keep their existing path policy. The full
configuration viewer uses its original fixed-argument command so the transient
override does not appear as a command-scope setting. This is
not a global change to filenames, case matching or URL grammar.

Network drafts compare proxy and SSH values exactly. The proxy adapter retains
its URL parsing/percent-encoding rules, password-cache ordering, sanitized
failures and global-only Git destination. The app's password adapter stores UTF-8
in Keychain; verification substitutes a private password actor. SSH still requires
an absolute executable OpenSSH path, existing bookmark/grant checks and bounded
version validation. App Store builds retain the bundled client and disable custom
selection. No new network or privileged helper is added.

## Verification boundary

The grouped implementation checkpoint is recorded in
[dated evidence](qa/settings-exact-text-2026-10-19.json). Private real Git configs
and hidden native forms can demonstrate exact edits and ownership; they do not
certify public authentication, production Keychain, signed configuration grants,
physical keyboard/VoiceOver behavior or every upstream setting. Multi-key saves
retain source ordering and Git file locks, with no atomic rollback promise.
The whole port and App Store distribution remain incomplete.


The selected Core group passed 20 methods, including four new exact-text cases.
The first Debug build exposed two ambiguous native helper-list expressions;
explicit comparison and a typed helper list repaired that compilation failure.
The relevant build then passed without repeating the unchanged Core group.
All six native case/engine combinations passed on their first native attempt.
All six receivers were reaped and independently absent by PID and process group.
The dated record retains original/final input hashes and the failed build log;
these results do not remove the remaining acceptance boundaries above.
