# Create patch file and General context setting

Source baseline: `7338078f8ddd924b8cddee35f512f2286072136d`.
`MainFrm.cpp::OnEditCreateunifieddifffile`, `AppUtils.cpp::CreateUnifiedDiff`,
`SetMainPage.cpp` and `IDD_SETMAINPAGE` define this workflow.

The two-file viewer provides **Create patch file** in its toolbar and the native
File menu while that comparison owns the key window. The source icon is retained.
A native Save panel proposes a `.diff` file; Cancel writes nothing. Single-file
views, busy/closing viewers and attached sheets disable the command. Ordinary
three-pane merges do not offer it. Closing or retiring a viewer fences late save
replies and cancels owned Git work.

Merge Editor settings now separate source **Misc** and **Diffing** groups from
additional comparison/view options. **Context lines for patches** accepts the
source range -1 through 1000. -1 omits `--unified` so Git uses its default; zero
omits surrounding lines. Apply persists the value; Cancel restores it. Invalid
values block the complete settings transaction. General settings accept isolated
preference/profile locations for native verification.

As upstream does, generation uses Git `diff --no-index`, accepting exits 0 and 1.
Working inputs are read from saved files at export time; unsaved editor drafts
and display whitespace/case/regex filters do not alter the patch. Historical
inputs retain their captured revision bytes. Private temporary inputs preserve
regular/executable/symlink modes. Header names retain comparison paths (absolute
standalone paths use their file names) and never expose temporary locations.
Git C-style quoting preserves spaces, tabs, quotes and Unicode; hunk bytes are
never decoded, so legacy text and CRLF remain intact. Missing sides use
`/dev/null`. Output is written atomically with the save-panel lease held.

The source command does not request `--binary`; binary differences produce Git's
diagnostic rather than an applicable binary payload. This behavior is retained.

The combined one-pane workflow/default is now implemented; see
[one-pane parity](MERGE-ONE-PANE-PARITY.md). Default to UTF-8 remains open. Windows Ribbon preferences require a native toolbar adaptation.
The Colors page now has native per-channel Automatic/More colors controls,
independent palette drafts and Restore Default. See [Colors parity](MERGE-COLORS-PARITY.md)
for panel lifecycle and remaining theme/physical acceptance. Exact physical
page/menu layout, save-panel overwrite/grant acceptance and signed Store
sandbox acceptance remain open. Focused checks do not certify the full family.
