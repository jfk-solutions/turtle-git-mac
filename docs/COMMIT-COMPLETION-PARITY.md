# Commit filename completion audit

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
This records a partial editor port; complete Commit parity remains outstanding.

## Source mapping

| Source | Native implementation | Behavior |
| --- | --- | --- |
| CommitDlg.cpp::GetAutocompletionList | MessageCompletion.fileCandidates | Every displayed path and every slash suffix, including unchecked and unversioned rows |
| SciEdit.cpp::DoAutoCompletion | MessageCompletion.request/matches | End-of-word gate, default three-character automatic trigger, original/lower/upper variants, hyphen-part matches and literal UTF-16 ordering |
| SetDialogs2.cpp / SettingsAdvanced.cpp | CommitEditorSettings | Saved Autocompletion (default true), AutoCompleteMinChars (default 3) and AutocompleteRemovesExtensions (default false) |
| IDI_FILE / Resources/file.ico | CommitCompletionPopup | Original unmodified file icon in a native AppKit popover |

The extension option adds only the last basename without its last extension;
a leading dot alone is retained. Canonically equivalent filenames remain
separate literal UTF-16 keys, as in the source map. Marker trimming retries the
full word when it finds no completion.

Ctrl-Space requests completion after one character. Option-Escape is a macOS
alias. Arrow keys select; Return, Tab or a mouse click accepts; Escape dismisses.
Acceptance replaces the requested prefix and forms a separate Undo operation.
The popup uses the caret's native layout geometry and dynamic light/dark colors.
A tooltip retains the entire filename when a long row is truncated.

## Verified behavior

Four focused completion tests cover path suffixes, extension rules, literal
Unicode identity/order, minimum lengths, casing/hyphen variants, end-of-word and
selection gates, marker fallback and replacement ranges. The full local suite
passed 389 tests with zero failures. Unsigned Debug and App Store builds and
bundle audits passed, including all 65 original icon resources.

Native acceptance used a disposable repository with a checked modified
`src/nested/Widget.swift` and unchecked unversioned `Window.swift`. Two typed
characters did not show the automatic popup; the third did. Tab acceptance and
Undo preserved the prefix. Manual Ctrl-Space, Option-Escape, arrow/Return and
mouse acceptance were exercised. A saved disabled switch suppressed Ctrl-Space;
re-enabling it with the extension option produced Widget, Widget.swift, Window
and Window.swift. Undo after mouse acceptance restored the one-character draft.
Actual light and dark captures were inspected. All QA processes quit normally,
and HEAD, raw index and tracked working bytes remained identical to baseline.

See [recorded acceptance](qa/commit-completion-2026-10-05.json).

## Still outstanding

- Shipped/user autolist.txt definitions, code-symbol regex extraction and file
  decoding, parse timeout/size limits and unversioned-content parsing preference.
- Shipped/user snippet.txt loading, snippet icons and expansion semantics.
- Spelling dictionaries, custom words, Ctrl-Tab suggestions and dictionary-aware
  completion behavior.
- Exact Windows locale casing/word classification, arbitrary DWORD minimums,
  empty-prefix edge cases, full Scintilla popup lifecycle and Tab focus behavior.
- Large catalogs, input methods, accessibility navigation, signed sandbox
  acceptance and the remaining Commit/settings controls.

The native minimum editor currently offers 1–100 characters. The filename
catalog is computed from current visible rows rather than the source's timed
background scan. Remaining scanner and full settings work must preserve the
source behavior before full parity can be claimed. GitHub verification of these
local changes is pending publication.
