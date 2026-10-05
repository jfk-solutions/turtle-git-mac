# EditorConfig integration audit

TortoiseMerge `MainFrm.cpp:3510–3523,3671–3691` provides Tab/Space, Smart,
1/2/4/8 and EditorConfig in each pane menu. The four preset widths are upstream
behavior; arbitrary widths belong in Settings. `BaseView.cpp:217–240` resets
width/mode to saved defaults when EditorConfig is toggled and applies resolved
tab_width/indent_style to the reflected file path. The loaded state affects the
status label. `EditorConfigWrapper.cpp` uses the official C parser and also maps
ending, charset, whitespace and final-newline properties; callers' behavior
for all these properties still needs review.

## Official parser runtime foundation

`Configuration/EditorConfigRuntime.json` pins EditorConfig C Core 0.12.11,
PCRE2 10.49 and the exact official core-test submodule revision. Run
`python3 scripts/build-editorconfig-runtime.py` to build an arm64/x86_64 CLI
with static parser/PCRE2 archives and macOS 13 deployment target. The generated
package is `build/editorconfig-runtime/EditorConfig`, embedded in every Xcode
app configuration at `Contents/Helpers/EditorConfig`. It includes licenses, full unmodified source/test archives, the
reconstruction script and a provenance manifest. Archive extraction rejects
links and escaping paths; checksums are verified before extraction. Packaging
checks both architecture slices, declared minimum OS and system-only dynamic
linkage. Existing output without a provenance manifest is not replaced.

The 202 official core tests passed on the native architecture. Both CPU slices
were explicitly executed against inherited brace/numeric-glob rules, child
overrides and unset properties. Their load commands declare macOS 13.0; this
does not prove execution on an actual Intel macOS 13 host. See
[acceptance](qa/editorconfig-runtime-2026-10-05.json).

The CMake core target is unchanged. Its CLI is linked separately against static
archives because upstream's fully-static executable option adds Linux's
-static flag on Darwin. Both versioned/unversioned binary paths are supplied
to the unchanged official test wrappers. JIT is disabled; no Homebrew runtime
dependency is introduced.

## Native integration

The shared per-pane tab menu now has EditorConfig after the width presets, off
unless the saved Enable EditorConfig default is enabled. Both comparison and conflict editors resolve the reflected original
file path, reset width/mode/Smart to saved defaults on each toggle, then apply
only resolved tab_width and indent_style. Matching properties add the upstream
EC suffix. Read-only source panes have independent view settings. Toggling or
reloading settings does not rewrite text, encoding, line endings or Undo history.
Reload re-reads enabled panes; changing indentation preferences resets them and
re-applies EditorConfig. Line-number-only changes retain tab overrides.

The Swift reader runs the pinned CLI off the main thread, uses file-backed
output, rejects missing/malformed parsers and bounds execution to five seconds
plus a one-second termination grace. Per-pane request IDs discard stale reads.
Pane menus are disabled while a read is in progress. App Store comparisons
request a selected containing folder if a file bookmark cannot cover config
reads. Scopes stay held while the model's read completes. Ancestors outside the
selected scope remain inaccessible; full ancestor permission UI and signed
scope acceptance are still pending.

Build signing uses an inherited sandbox entitlement only for AppStore. Debug
and Release helpers use normal hardened-runtime signing. Both ad-hoc signing
branches were exercised: hashes, signatures, universal slices, pins and resources
passed. An inherited helper traps when launched from an unsandboxed build tool;
the validator therefore executes the unsigned package before signing and checks
the signed helper's exact entitlements afterwards. This is not proof of a signed
App Store app invocation. Debug preview signing updates parser provenance and
reseals the modified manifest and app.

Native QA verified independent conflict Mine/Merged settings, Space 7 EC,
seven-space indentation and Undo, disabling to Tab 4, and a changed rule becoming
Space 5 EC after Reload. A two-pane comparison independently loaded Space 5 EC
in Mine, indented by five spaces and returned clean after Undo. Source/working
bytes, HEAD, raw index and executable mode stayed unchanged. All QA app instances
were closed. See [acceptance](qa/editorconfig-native-2026-10-05.json).

## Saved default and save-call audit

The General page now includes upstream's Enable EditorConfig checkbox. Its
false default and saved key are mapped to UserDefaults. New comparison/conflict
views capture that default, including hidden Base. Changing it in Settings does
not override open panes' session toggles, matching BaseView constructor reads
and MainFrm OnViewOptions/DocumentUpdated. Native Apply, restart persistence and
enabling/disabling defaults were accepted. Full upstream settings reload and
save-prompt behavior remains partial.

A scan of all 71 root TortoiseMerge implementation/header files at the inventory
commit verified every Git blob hash. The only wrapper construction is in
BaseView.SetEditorConfigEnabled, which consumes tab_width and indent_style.
Parsed indent_size, charset, end_of_line, trim_trailing_whitespace and
insert_final_newline have no other consumer in that source scope. Save callers
use the selected pane encoding/endings. Native Save confirmed exact UTF16LE BOM,
CRLF, trailing whitespace and no final newline despite differing config values;
HEAD/index and mode stayed intact. These unused fields are retained as raw
properties and do not trigger extra save transformations. This resolves the
previous save-property audit question for the pinned baseline.

Numeric width follows the wrapper's atoi and BaseView's 1...1000 clamp, including
unset/nonnumeric values becoming one and numeric prefixes being accepted. This
is explicit upstream behavior rather than stricter property validation. See
[default/save acceptance and source hashes](qa/editorconfig-defaults-2026-10-05.json).

## Remaining parity

Full preference reload/save-prompt acceptance,
native failure/timeout and race acceptance, signed sandbox reads with folder
bookmarks, ancestor permissions, dark/narrow layouts and actual Intel/macOS13
execution remain pending. Exact writable/loaded menu availability still differs:
upstream gates menu commands by view writability and the EditorConfig loaded
state; native read-only panes currently allow view-setting changes. Full source
editing and those gates remain partial. The 358 local tests and unsigned app builds
do not establish full EditorConfig parity or App Store readiness.

Sources: [TortoiseMerge wrapper](https://raw.githubusercontent.com/TortoiseGit/TortoiseGit/master/src/TortoiseMerge/EditorConfigWrapper.cpp),
[official C core](https://github.com/editorconfig/editorconfig-core-c),
[EditorConfig specification](https://spec.editorconfig.org/).
