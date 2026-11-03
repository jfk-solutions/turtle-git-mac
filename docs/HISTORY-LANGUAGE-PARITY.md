# History and reference menu languages

Pinned upstream: `7338078f8ddd924b8cddee35f512f2286072136d`.
`GitLogListBase.cpp` constructs revision menus from localized resource IDs;
`BrowseRefsDlg.cpp` does the same for reference actions. Native AppKit previously
received their English captions directly despite the bundled label catalog.

This batch connects Log, Browse References and RefLog together: revision,
working-tree, stash, multiple-selection and parent menus; clipboard submenus;
column headers and visibility menus; reference folder/pair commands; search/filter
choices; runtime limit and ordering choices; and related fixed native form labels.
It preserves semantic IDs, payloads, shortcuts, icons, checked/enabled states,
sorting keys and saved column identifiers. Menu owner/epoch guards remain active.

`HistoryLabels` resolves static captions and validates named caption fields before
inserting repository data once. A translation with missing, extra, repeated or
malformed fields falls back to the English template. Branch/ref/path/subject
values are never looked up, interpreted as C formatting, or substituted a second
time. German and French native adaptations cover composed history captions.
Unusable, ambiguous, fuzzy, missing or unsupported source entries keep English.

The production consumers are `LogWindow.swift`, `LogFilterField.swift`,
`LogMessageView.swift`, `LogOrderingWindow.swift`, `ReferenceBrowserWindow.swift`,
`ReferenceLogNativeTable.swift` and `ReferenceLogWindow.swift`. Shared parent
captions retain the existing UTF-16 truncation and raw hash/subject payloads.
The detached-branch caption is semantic only when no branch exists; a real branch
whose name matches an English label remains literal.

See [language instructions](LANGUAGES.md#history-and-reference-menus). The [resource-backed checkpoint](qa/history-languages-2026-10-31.json) passes
all four German/French and system/bundled Git combinations after one fixture
framing repair. The initial build name collision and native diagnostic warnings
remain recorded. No Core suite or unrelated native families were repeated. Core-produced information/footer
and graph accessibility prose, shared reference-deletion message formatting,
complete translation/CLDR coverage, physical menu/keyboard/VoiceOver and signed
translated-app acceptance remain open. Installed build47 predates this family.

## German/French feedback runtime checkpoint — November 3, 2026

The [runtime checkpoint](qa/history-remote-acceptance-2026-11-03.json) passes
German and French history processes with both Git engines. Native Log/References/
RefLog captions and actions, footer counts, deletion alerts/default Abort and
English fallback contracts execute with private preferences and repositories.
The partial RefLog failure presentation additionally checks independently stated
localized counts while preserving raw selectors, diagnostics, operation output
and Core English failure text. No production translation or label changed.

This supersedes the earlier pending native scope of the November 1 feedback
batch; it does not establish complete translation coverage, signed deployment
or physical keyboard/VoiceOver acceptance.
