$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$source='\\Mac\Home\Desktop\git\jfk-solutions\tortoise-git-mac\docs\qa\metafile-interpolation-reference-2026-11-05'
$work=Join-Path $env:TEMP ('TurtleGitInterpolationWire-'+[guid]::NewGuid().ToString())
$destination=Join-Path $source 'windows-wire-capture'
if(Test-Path $destination){throw 'Refuse existing capture destination'}
New-Item -ItemType Directory -Path $work|Out-Null
try{
 Copy-Item (Join-Path $source 'InterpolationReference.cpp'),(Join-Path $source 'WireVariants.cpp') $work
 Set-Location $work
 $build='call "C:\Program Files\Microsoft Visual Studio\18\Professional\VC\Auxiliary\Build\vcvarsall.bat" arm64 && cl /nologo /std:c++17 /EHsc /W4 WireVariants.cpp /Fe:WireVariants.exe /link gdiplus.lib user32.lib gdi32.lib'
 & cmd.exe /d /c $build 2>&1|Out-File -Encoding utf8 compiler.txt
 if($LASTEXITCODE -ne 0){throw "Compile exited $LASTEXITCODE"}
 & .\WireVariants.exe (Join-Path $source 'windows-capture\output') output 2>&1|Out-File -Encoding utf8 execution.txt
 if($LASTEXITCODE -ne 0){throw "Capture exited $LASTEXITCODE"}
 $report=Get-Content -Raw output/wire-variant-observations.json|ConvertFrom-Json
 if($report.completedCaseCount -ne 192){throw 'Incomplete aliases'}
 [pscustomobject]@{architecture=$env:PROCESSOR_ARCHITECTURE;version=[Environment]::OSVersion.VersionString;build=$build;guestDirectory=$work}|ConvertTo-Json|Set-Content -Encoding utf8 environment.json
 $runtimes=Get-Item "$env:WINDIR\System32\gdiplus.dll","$env:WINDIR\System32\gdi32.dll","$env:WINDIR\System32\win32u.dll"
 $runtimes|ForEach-Object{$_.VersionInfo|Select-Object FileName,FileVersion,ProductVersion}|ConvertTo-Json|Set-Content -Encoding utf8 runtime-versions.json
 $files=@(Get-ChildItem output -File)+@(Get-Item InterpolationReference.cpp,WireVariants.cpp,WireVariants.exe,compiler.txt,execution.txt,environment.json,runtime-versions.json)+@($runtimes)
 $files|Get-FileHash -Algorithm SHA256|Select-Object Path,Hash|ConvertTo-Json -Depth 3|Set-Content -Encoding utf8 sha256.json
 Copy-Item -Recurse $work $destination
 Write-Output ('CAPTURE: '+$destination)
}catch{($_|Out-String)|Set-Content -Encoding utf8 (Join-Path $work 'failure.txt');Copy-Item -Recurse $work $destination;throw}finally{Set-Location $env:TEMP;if(Test-Path $destination){Remove-Item -Recurse -Force $work}}
