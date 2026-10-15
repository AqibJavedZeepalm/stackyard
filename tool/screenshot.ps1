# Captures the Stackyard window to a PNG.
#   powershell -File tool/screenshot.ps1 -Out screenshots/01-overview.png
param([Parameter(Mandatory)] [string] $Out, [string] $Process = 'stackyard')

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Win {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
}
'@
[Win]::SetProcessDPIAware() | Out-Null

$p = Get-Process $Process -ErrorAction SilentlyContinue | Where-Object MainWindowHandle -ne 0 | Select-Object -First 1
if (-not $p) { Write-Error "No $Process window"; exit 1 }
$h = $p.MainWindowHandle
[Win]::ShowWindow($h, 9) | Out-Null   # restore if minimized
[Win]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 600

# Visible bounds without the invisible resize border.
$r = New-Object Win+RECT
[Win]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) | Out-Null
$w = $r.R - $r.L; $hgt = $r.B - $r.T
$bmp = New-Object System.Drawing.Bitmap $w, $hgt
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)

# If the screen is locked, CopyFromScreen gives black; fall back to PrintWindow.
$probe = $bmp.GetPixel([int]($w / 2), [int]($hgt / 2))
if ($probe.R -eq 0 -and $probe.G -eq 0 -and $probe.B -eq 0) {
  $dc = $g.GetHdc(); [Win]::PrintWindow($h, $dc, 2) | Out-Null; $g.ReleaseHdc($dc)
}
$g.Dispose()
New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
$bmp.Save((Resolve-Path -LiteralPath (Split-Path $Out)).Path + '\' + (Split-Path $Out -Leaf), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
"saved $Out ($w x $hgt)"
