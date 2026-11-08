$ErrorActionPreference = 'Stop'
# Build a spec-compliant multi-size ICO (PNG payload, Vista+).
# Icon.FromHandle().Save() writes handle-derived icons Explorer often rejects.
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO

$d = $PSScriptRoot
while ($d -and -not (Test-Path -LiteralPath (Join-Path $d 'registry'))) { $d = Split-Path $d -Parent }
if (-not $d) { throw 'cannot locate project root (no registry\ found above the script)' }
$IconPath = Join-Path $d 'app\post.ico'

function New-EnvelopePng([int]$s) {
    $bmp = New-Object System.Drawing.Bitmap($s, $s)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $scale = $s / 32.0
    $body = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 99, 102, 241))
    $g.FillRectangle($body, [single](2*$scale), [single](7*$scale), [single](28*$scale), [single](19*$scale))
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, [single][Math]::Max(1.5, 2*$scale))
    $pts = @(
        (New-Object System.Drawing.PointF([single](3*$scale), [single](8*$scale))),
        (New-Object System.Drawing.PointF([single](16*$scale), [single](19*$scale))),
        (New-Object System.Drawing.PointF([single](29*$scale), [single](8*$scale)))
    )
    $g.DrawLines($pen, $pts)
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return ,$ms.ToArray()
}

$sizes = @(16, 24, 32, 48)
$images = @()
foreach ($s in $sizes) { $images += ,@{ size = $s; bytes = (New-EnvelopePng $s) } }

$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$images.Count)
$offset = 6 + 16 * $images.Count
foreach ($img in $images) {
    $s = $img.size
    $w = if ($s -ge 256) { 0 } else { $s }
    $bw.Write([byte]$w); $bw.Write([byte]$w); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$img.bytes.Length); $bw.Write([uint32]$offset)
    $offset += $img.bytes.Length
}
foreach ($img in $images) { $bw.Write($img.bytes) }
$bw.Flush()
[System.IO.File]::WriteAllBytes($IconPath, $ms.ToArray())
$bw.Dispose()
Write-Host ('icon written: ' + (Get-Item $IconPath).Length + ' bytes (multi-size PNG-in-ICO)')

# sanity: load it back the same way the app will
$i = New-Object System.Drawing.Icon($IconPath, (New-Object System.Drawing.Size(16,16)))
Write-Host ('reload sanity ok: ' + $i.Width + 'x' + $i.Height)
$i.Dispose()
