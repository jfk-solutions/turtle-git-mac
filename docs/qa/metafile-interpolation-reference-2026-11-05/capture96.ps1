$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$source = '\\Mac\Home\Desktop\git\jfk-solutions\tortoise-git-mac\docs\qa\metafile-interpolation-reference-2026-11-05'
$work = Join-Path $env:TEMP ('TurtleGitInterpolation96-' + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $work | Out-Null
$destination = Join-Path $source 'windows-capture96'
if (Test-Path $destination) { throw 'Capture destination already exists; refuse overwrite' }
try {
    Copy-Item (Join-Path $source 'InterpolationReference96DPI.cpp') $work
    Set-Location $work
    $build = 'call "C:\Program Files\Microsoft Visual Studio\18\Professional\VC\Auxiliary\Build\vcvarsall.bat" arm64 && cl /nologo /std:c++17 /EHsc /W4 InterpolationReference96DPI.cpp /Fe:InterpolationReference96DPI.exe /link gdiplus.lib user32.lib gdi32.lib'
    & cmd.exe /d /c $build 2>&1 | Out-File -Encoding utf8 compiler.txt
    if ($LASTEXITCODE -ne 0) { throw "Compiler exited $LASTEXITCODE" }
    & .\InterpolationReference96DPI.exe output 2>&1 | Out-File -Encoding utf8 execution.txt
    if ($LASTEXITCODE -ne 0) { throw "Reference exited $LASTEXITCODE" }
    $report = Get-Content -Raw output/interpolation-observations.json | ConvertFrom-Json
    if ($report.completedCaseCount -ne 192 -or $report.cases.Count -ne 192) { throw 'Incomplete native case inventory' }
    foreach ($case in $report.cases) {
        foreach ($suffix in @('-direct.rgba', '-natural.rgba', '-picture.rgba')) {
            if ((Get-Item ('output/' + $case.name + $suffix)).Length -ne (32 * 24 * 4)) { throw 'Capture byte count mismatch' }
        }
    }
    [pscustomobject]@{ architecture=$env:PROCESSOR_ARCHITECTURE; version=[Environment]::OSVersion.VersionString; build=$build; guestDirectory=$work; count=$report.completedCaseCount } | ConvertTo-Json | Set-Content -Encoding utf8 environment.json
    $runtimes = Get-Item "$env:WINDIR\System32\gdiplus.dll", "$env:WINDIR\System32\gdi32.dll", "$env:WINDIR\System32\win32u.dll"
    $runtimes | ForEach-Object { $_.VersionInfo | Select-Object FileName,FileVersion,ProductVersion } | ConvertTo-Json | Set-Content -Encoding utf8 runtime-versions.json
    $files = @(Get-ChildItem output -File) + @(Get-Item InterpolationReference96DPI.cpp, InterpolationReference96DPI.exe, compiler.txt, execution.txt, environment.json, runtime-versions.json) + @($runtimes)
    $files | Get-FileHash -Algorithm SHA256 | Select-Object Path,Hash | ConvertTo-Json -Depth 3 | Set-Content -Encoding utf8 sha256.json
    if ((Get-ChildItem output -File | Measure-Object Length -Sum).Sum -gt 16MB) { throw 'Reference output budget exceeded' }
    Copy-Item -Recurse $work $destination
    Write-Output ('CAPTURE: ' + $destination)
} catch {
    ($_ | Out-String) | Set-Content -Encoding utf8 (Join-Path $work 'failure.txt')
    Copy-Item -Recurse $work $destination
    throw
} finally {
    Set-Location $env:TEMP
    # Retain only the transferred copy; no executable or captures remain in guest Temp.
    if (Test-Path $destination) { Remove-Item -Recurse -Force $work }
}
