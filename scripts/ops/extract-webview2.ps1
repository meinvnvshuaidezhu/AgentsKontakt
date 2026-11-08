$ErrorActionPreference = 'Stop'
$d = $PSScriptRoot
while ($d -and -not (Test-Path -LiteralPath (Join-Path $d 'registry'))) { $d = Split-Path $d -Parent }
if (-not $d) { throw 'cannot locate project root (no registry\ found above the script)' }
Set-Location $d
Add-Type -AssemblyName System.IO.Compression.FileSystem
$z = [System.IO.Compression.ZipFile]::OpenRead($d + '\vendor\webview2.zip')
$want = @(
    'lib/net462/Microsoft.Web.WebView2.Core.dll',
    'lib/net462/Microsoft.Web.WebView2.WinForms.dll'
)
foreach ($e in $z.Entries) {
    if ($want -contains $e.FullName) {
        $dest = Join-Path ($d + '\vendor') ($e.FullName.Replace('/', '\'))
        $dd = Split-Path $dest -Parent
        if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dest, $true)
        Write-Host ('extracted: ' + $dest + ' (' + $e.Length + ' bytes)')
    }
}
$z.Dispose()
Copy-Item $d + '\vendor\lib\net462\Microsoft.Web.WebView2.Core.dll' $d + '\app\' -Force
Copy-Item $d + '\vendor\lib\net462\Microsoft.Web.WebView2.WinForms.dll' $d + '\app\' -Force
Get-ChildItem $d + '\app' -File | ForEach-Object { Write-Host $_.Name + ' (' + $_.Length + ')' }
