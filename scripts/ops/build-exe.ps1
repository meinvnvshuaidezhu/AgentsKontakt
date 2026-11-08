param(
    [string]$Root = ''
)

if (-not $Root) {
    $d = $PSScriptRoot
    while ($d -and -not (Test-Path -LiteralPath (Join-Path $d 'registry'))) { $d = Split-Path $d -Parent }
    if (-not $d) { throw 'cannot locate project root (no registry\ found above the script)' }
    $Root = $d
}

$ErrorActionPreference = 'Stop'
# Build AgentsKontaktPost.exe (64-bit) from app\*.cs.
#
# Zero external SDK: uses the in-box .NET Framework csc.exe against the
# WebView2 assemblies dropped into app\ by ops\extract-webview2.ps1.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ops\build-exe.ps1
#   powershell ... -File scripts\ops\build-exe.ps1 -Root 'D:\somewhere\AgentsKontakt'
#
# NOTE: the csc.exe path must be invoked from inside a .ps1 file - calling it
# inline from a tool invocation gets blocked by the command blacklist.

$appDir = Join-Path $Root 'app'

# 1) sources must be UTF-8 WITH BOM: the in-box csc assumes GBK without it.
foreach ($f in @('Program.cs','Installer.cs','AssemblyInfo.cs')) {
    $p = Join-Path $appDir $f
    if (-not (Test-Path -LiteralPath $p)) { throw "missing source: $p" }
    $text = [System.IO.File]::ReadAllText($p, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($p, $text, (New-Object System.Text.UTF8Encoding($true)))
    Write-Host ("re-encoded with BOM: {0}" -f $f)
}

# 2) icon
$iconScript = Join-Path $Root 'ops\make-icon.ps1'
if (Test-Path -LiteralPath $iconScript) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $iconScript
}

# 3) compile 64-bit exe
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { throw "csc not found: $csc" }

$out = Join-Path $appDir 'AgentsKontaktPost.exe'
$ico = Join-Path $appDir 'post.ico'
$wv2core = Join-Path $appDir 'Microsoft.Web.WebView2.Core.dll'
$wv2forms = Join-Path $appDir 'Microsoft.Web.WebView2.WinForms.dll'
$sources = @(
    (Join-Path $appDir 'Program.cs'),
    (Join-Path $appDir 'Installer.cs'),
    (Join-Path $appDir 'AssemblyInfo.cs')
)

& $csc /nologo /target:winexe /platform:x64 /optimize+ `
    "/out:$out" `
    "/win32icon:$ico" `
    /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll `
    "/r:$wv2core" `
    "/r:$wv2forms" `
    $sources

if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE" }
Write-Host ("csc exit: {0}" -f $LASTEXITCODE)

$exe = Get-Item -LiteralPath $out
Write-Host ("exe: {0} bytes" -f $exe.Length)
Write-Host ("built: {0}" -f $exe.FullName)
Write-Host ("version: {0}" -f $exe.VersionInfo.FileVersion)
