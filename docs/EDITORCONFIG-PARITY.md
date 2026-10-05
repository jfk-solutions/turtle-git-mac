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
package is `build/editorconfig-runtime/EditorConfig`, not yet embedded in the
application. It includes licenses, full unmodified source/test archives, the
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

## Remaining integration

The native menu toggle, pane settings mapping, loaded indicator and bundled
helper are not wired yet. App Store embedding/signing, asynchronous reads and
error/cancellation handling, ancestor-file security scopes, native editing and
preference reload acceptance remain necessary. Save-time charset/EOL/whitespace/
final-newline behavior needs its own upstream audit. A passing standalone core
suite does not establish EditorConfig feature parity or App Store readiness.

Sources: [TortoiseMerge wrapper](https://raw.githubusercontent.com/TortoiseGit/TortoiseGit/master/src/TortoiseMerge/EditorConfigWrapper.cpp),
[official C core](https://github.com/editorconfig/editorconfig-core-c),
[EditorConfig specification](https://spec.editorconfig.org/).
