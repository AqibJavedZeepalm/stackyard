# Installs the release build for the current user (no admin needed):
#   %LOCALAPPDATA%\Programs\Stackyard, Start menu + desktop shortcuts, and an
#   entry in Settings > Apps so it can be uninstalled like any other app.
#   powershell -File tool/install.ps1 [-From <Release folder>]
param([string]$From = (Join-Path $env:LOCALAPPDATA 'sy\build\windows\x64\runner\Release'))
$ErrorActionPreference = 'Stop'

$exe = Join-Path $From 'stackyard.exe'
if (-not (Test-Path $exe)) { throw "No build at $From. Run: powershell -File tool/dev.ps1 build windows --release" }

$dest = Join-Path $env:LOCALAPPDATA 'Programs\Stackyard'
$startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Stackyard.lnk'
$desktop = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Stackyard.lnk'
$regKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Stackyard'

Get-Process stackyard -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$dest*" } | Stop-Process -Force
New-Item -ItemType Directory -Force $dest | Out-Null
robocopy $From $dest /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "Copy failed (robocopy $LASTEXITCODE)" }

$target = Join-Path $dest 'stackyard.exe'
$shell = New-Object -ComObject WScript.Shell
foreach ($lnk in $startMenu, $desktop) {
  $s = $shell.CreateShortcut($lnk)
  $s.TargetPath = $target
  $s.WorkingDirectory = $dest
  $s.IconLocation = "$target,0"
  $s.Description = 'See and manage every SDK and toolchain version on your machine.'
  $s.Save()
}

# Uninstaller: removes the app folder, shortcuts and this entry. Settings and the
# size cache (in %APPDATA%) are left alone.
$uninstall = Join-Path $dest 'uninstall.ps1'
@"
Get-Process stackyard -ErrorAction SilentlyContinue | Where-Object { `$_.Path -like '$dest*' } | Stop-Process -Force
Remove-Item -LiteralPath '$startMenu', '$desktop' -ErrorAction SilentlyContinue
Remove-Item -LiteralPath '$regKey' -Recurse -ErrorAction SilentlyContinue
Set-Location `$env:TEMP
Remove-Item -LiteralPath '$dest' -Recurse -Force
"@ | Set-Content -Encoding UTF8 $uninstall

$version = (Get-Item $target).VersionInfo.ProductVersion
$size = [int]((Get-ChildItem $dest -Recurse -File | Measure-Object Length -Sum).Sum / 1KB)
New-Item -Force $regKey | Out-Null
$props = @{
  DisplayName = 'Stackyard'; DisplayVersion = $version; Publisher = 'Stackyard contributors'
  DisplayIcon = "$target,0"; InstallLocation = $dest; EstimatedSize = $size; NoModify = 1; NoRepair = 1
  UninstallString = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$uninstall`""
}
foreach ($k in $props.Keys) {
  $type = if ($props[$k] -is [int]) { 'DWord' } else { 'String' }
  New-ItemProperty -Path $regKey -Name $k -Value $props[$k] -PropertyType $type -Force | Out-Null
}
Write-Output "Installed Stackyard $version to $dest"
