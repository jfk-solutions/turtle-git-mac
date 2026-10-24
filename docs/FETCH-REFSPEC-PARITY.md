# Fetch and Pull literal refspecs

This family implements the existing Fetch/Pull dialog's single remote-branch
field as a literal Git refspec argument. It does not introduce additional fields,
patterns, shell parsing or multiple-refspec syntax.

## Pinned source and accepted input

The source is TortoiseGit commit
`7338078f8ddd924b8cddee35f512f2286072136d`:

- `src/TortoiseProc/PullFetchDlg.cpp:426–458` captures the field verbatim. Named
  remote Fetch omits it when NamedRemoteFetchAll is enabled. Pull omits it when
  that setting is enabled and the selected remote/branch equals configured
  tracking. The URL radio retains the field.
- `src/TortoiseProc/AppUtils.cpp:2271–2330,2521–2665` quotes the captured field as
  one argument to ordinary Git Pull/Fetch. It does not first require a branch
  name with `check-ref-format`.
- `src/TortoiseProc/ProgressCommands/FetchProgressCommand.cpp:48–86` implements
  the separate selected-libgit2 behavior described below.
- `src/TortoiseProc/SyncDlg.cpp:409–465` constructs its own branch/tracking
  mappings. Synchronization's branch field is not changed by this family.

Core now removes branch-name-only prevalidation. It trims outer whitespace as
existing native submission does, rejects embedded NUL in an active field, then
passes the resulting string as exactly one argument after the remote. Git
validates force prefixes, source/destination mappings, wildcard and negative
refspecs. An invalid refspec produces the actual engine failure and output;
it is not reported as an invalid branch before transport. A field containing
spaces is still one argument, not several refspecs.

A command-only `-c core.precomposeunicode=false` preserves literal decomposed
reference bytes for Fetch, Pull and the associated Rebase target lookups, even
when stored repository configuration enables worktree filename precomposition.
This override does not rewrite configuration. Public failure receipts retain the
Fetch/Pull command arguments and streamed-output delivery metadata.

## Existing option and engine distinctions

All-remotes Fetch and named-all omission remain unchanged. Pull's exact
configured-tracking omission remains unchanged. Tags and prune retain their
three-state flags, and depth, verbosity, SSH preparation and cancellation retain
their existing behavior. Default CLI operation remains CLI; selected Fetch uses
the captured libgit2 configuration. Pull remains ordinary Git.

Selected libgit2 intentionally follows the pinned source rather than replacing
it with CLI refspec semantics:

1. Look up the named remote, falling back to an anonymous URL remote.
2. If the single field is nonempty, call `git_remote_add_fetch` with the raw
   refspec. This changes the named remote's stored fetch configuration.
3. Fetch with a null explicit-refspec array on the **already loaded** remote.
   The newly persisted mapping applies to a later operation, not that first
   operation's loaded refspec set.

The current helper already implements this ordering; this family exposes valid
input to it. A nonempty refspec on an anonymous URL remote fails because there is
no named configuration identity. The actual library's refspec support and error
are retained, including differences from the selected CLI Git version. No retry
falls back to CLI or rewrites the field into a conventional tracking mapping.
Existing source-specific handling of force and tag defaults is unchanged.

## Fetch followed by Rebase

The effective field also follows the pinned dialog's named-all omission. Fetch
no longer forces a displayed branch into the transport when named-all is
selected. Pull followed by Rebase omits it only for the exact byte-identical
configured tracking selection; a different field remains explicit. The handoff
retains the exact source Rebase preset:

- A named remote with an effective nonempty field produces
  `remotes/<remote>/<raw field>`, without stripping `refs/heads/` or interpreting
  a mapping, force prefix, wildcard or negative expression.
- If the named-all setting omits the field, the preset uses the current branch's
  configured remote/merge branch only when that remote matches. Otherwise the
  empty preset opens the ordinary Rebase chooser.
- An arbitrary URL uses `FETCH_HEAD`.

`FetchRebaseResult.upstreamPreset` retains that spelling. If it resolves to a
commit after successful Fetch, `upstreamResolved` is true and `upstream` captures
its immutable object ID; later ref movement cannot change that accepted target.
If it does not resolve, `upstreamResolved` is false and `upstream` is the literal
editable preset. No ancestry/fast-forward/up-to-date decision is manufactured.
Native Rebase opens that preset for editing instead of silently choosing the
refspec destination or an unrelated `FETCH_HEAD`. A successful Fetch with an
unresolved preset is not reported as a failed Fetch.

An empty/missing ref is distinguished from a metadata process failure: quiet
resolution exit 1 means unresolved; unexpected execution failures or invalid
successful object-ID output retain the successful transport diagnostics in
`FetchRebaseExecutionFailure`. Cancellation remains cancellation. The existing
all-remotes Rebase guard remains a Mac profile constraint.

Pinned source selected libgit2 returns before the automatic CLI handoff. The Mac
retains its existing selected-library continuation as an explicit extension,
using the same raw preset/immutable-resolution rules. Ordinary resolved targets
remain immutable; this changes the previous CLI named-remote `FETCH_HEAD`
adaptation when it conflicted with the source preset. See also
[Fetch parity](FETCH-PARITY.md).

## Validation scope and remaining limits

The grouped checkpoint records 51 distinct Core methods cumulatively passing,
including thirteen new `FetchRefspecTests` methods covering:

- exact decomposed Unicode mapping/argv with stored precomposition enabled,
  unchanged staged index and remote configuration, plus packed NFC/NFD branches
  proving Pull/Rebase tracking omission uses byte identity;
- wildcard mappings and forced/non-fast-forward local branch updates;
- arbitrary-URL mapping with explicit tags/prune overrides;
- a single negative refspec compared with direct execution of the same Git;
- Pull mapping/fast-forward and actual malformed-refspec diagnostics;
- structural NUL refusal, inactive-field omission and cancellation before
  transport;
- selected-libgit2 first-read versus later-read configuration effects,
  anonymous/malformed failures, raw editable Rebase presets, immutable resolved
  targets and named-all tracking/default-chooser handoff.

Retained source-Rebase fixtures now request explicit branches where intended
and assert editable unresolved presets instead of selecting unrelated fetched
commits. The retained invalid-input test now uses NUL, rather than labeling an
ordinary source/destination mapping as injection. The retained Rebase diagnostic fake
recognizes invocation-only Git configuration flags rather than assuming a fixed
argument position. Native form/history/retry/ownership acceptance passes in six distinct CLI
case/engine pairs: Fetch, Pull and Rebase with system and bundled Git. The first
Pull native attempt exposed a missing submitted-command receipt in progress;
the repair streams that captured receipt through the existing parser while
preserving raw Git output for Core observers. Two affected Core methods and four
affected native pairs then passed. The final Debug build exited zero, with one
contradictory generic compiler exit-zero diagnostic recorded.

Retained streaming/cancellation/forced-cleanup fixtures inspect Git global
options rather than relying on fixed argument positions. Cancellation requires
the exact retained result, its cancellation diagnostic and failure state, while
keeping process, unrelated-process, HEAD/index and close assertions.
See the [dated checkpoint](qa/fetch-refspec-family-2026-10-24.json) for initial
failures, focused repairs and retained-check results. These checks do not
establish every server's refspec support,
signed deployment or a full hosted CI pass.
