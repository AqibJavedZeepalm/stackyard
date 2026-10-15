# Mirrors the project to a short path and runs Flutter there.
# MSBuild fails (FTK1011) when the project path is too long, as it is in this workspace.
#   powershell -File tool/dev.ps1 build windows --debug
#   powershell -File tool/dev.ps1 test integration_test/real_machine_test.dart -d windows
$src = Split-Path $PSScriptRoot -Parent
$dst = Join-Path $env:LOCALAPPDATA 'sy'
robocopy $src $dst /MIR /XD build .dart_tool screenshots ephemeral .symlinks /XJ /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { Write-Error "robocopy failed ($LASTEXITCODE)"; exit 1 }
# MSBuild doesn't notice when only app_icon.ico changes, so the exe would keep the
# old icon. Drop the compiled resources whenever the icon is newer.
$ico = Join-Path $dst 'windows\runner\resources\app_icon.ico'
Get-ChildItem (Join-Path $dst 'build\windows') -Recurse -Filter Runner.res -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -lt (Get-Item $ico).LastWriteTime } | Remove-Item -Force
# Pick up tools installed since this shell started (e.g. by winget).
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
$flutter = Join-Path $env:USERPROFILE 'fvm\versions\3.47.7\bin\flutter.bat'
Push-Location $dst
try { & $flutter @args; $code = $LASTEXITCODE } finally { Pop-Location }
exit $code
