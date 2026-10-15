# Shared message formatting and issue links

Source pin: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`InputDlg.cpp::OnInitDialog`, `AppUtils.cpp::EditNote`, `SciEdit.cpp` issue/URL/
formatting passes, `MergeDlg.cpp`, `RebaseDlg.cpp` message initialization and
`BrowseRefsDlg.cpp::eCmd_EditBranchDescription`.

The native Input form used for Notes and branch descriptions, Merge messages and
Rebase Edit/Squash messages now share the attributed-text renderer already used
by Commit. Source bold (`*`), italic (`^`) and underline (`_`) passes retain their
existing ordering with issue contexts/identifiers and URL hotspots. The existing
UTF-8 ECMAScript helper determines issue spans; native UTF-16 ranges, URL targets
and tooltips reach the editable text view. Links remain a user interaction; merely
styling a message never opens a browser. Editors remain plain text.

Log/Rebase note presenters and the Synchronization note form load effective issue
properties with their owned note/project reads. Merge and Rebase capture the
properties during initial metadata loading. Those reads use existing cancellation,
permission and late-result guards. Branch descriptions follow the source's
`Init(-1)` route: no repository issue expression and no project spelling, while
ordinary URL/text formatting remains available. The source `m_bUseLogWidth`
actually gates project minimum message length; it does not require descriptions
to inherit a repository's project settings.

Saved StyleCommitMessages controls formatting without removing issue/URL links.
Fonts and spelling use the owning preference store; live font/style changes
refresh presentation. Source width markers use the base font. Applying attributes
preserves text bytes, selection and Undo; inserted text retains its normal edit
history. IME marked text is left alone and restyled after unmarking. Programmatic
message replacement schedules a fresh projection instead of reusing old offsets.

Each additional editor owns a debounced styling session. A new draft or closed/
detached editor cancels its request and regex process token. Old results cannot
style replacement text or a retired view. The Commit styler now passes the same
cancellation token into its existing backend. Started queries stay counted through
settlement for application Quit, including after their view closes. Pending timers
are cancellable and do not represent a running child process. Invalid issue
expressions retain the existing URL/formatting fallback; cancellation does not
start that fallback.

## Evidence and remaining work

See [the dated record](qa/message-styles-2026-10-15.json) for actual build/Core/
native results, repairs, owner cleanup and any reviewed screenshots. The grouped
native receiver combines source-style projection with retained Input, note-host
and spelling checks; it supports focused repair rechecks and content-key caching.
Native checks inspect actual attributed editors, captured note bytes and Git state;
these do not prove physical link clicking, keyboard/VoiceOver, every IME/locale,
all upstream Scintilla behavior or signed sandbox/App Store acceptance.

The source's supplementary-character formatting boundary quirk remains: markers
following an emoji on the same line can remain unstyled. The native reference
fixture therefore keeps emoji/issue text on one line and formatting on another;
four existing Core formatting tests retain that quirk and pass ordering.

Standalone native receivers now find IssueRegex in the companion Debug app
through the loaded Core framework. Packaged apps continue resolving their own
sealed helper, and explicitly supplied bundles remain unchanged. No system regex
engine or arbitrary executable fallback is introduced.

Debug, 14 focused style/regex Core cases and four retained formatting cases passed.
Nine distinct native cases passed across system/bundled Git, followed by the
affected final Commit/Merge font recheck after close cancellation was completed.
Two current raw Notes captures were reviewed and published. The record retains
failed diagnostics, repairs and exact case/process scope.
