<#
migrate-utf8bom.ps1 - one-time migration for the v2.3.8 encoding unification:
ensure every text file carries a UTF-8 BOM.

Idempotent by design:
  - files already starting with EF BB BF are left untouched
  - 0-byte files are skipped (nothing to declare)
  - files that do NOT decode as strict UTF-8 are reported and skipped -
    never rewritten blind

Default scope = the whole data root, excluding non-mailbox trees (backups,
vendor bundles, build outputs). Re-runnable at any time; a clean re-run
reports converted=0.

Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ops\migrate-utf8bom.ps1 [-Root <dir>] [-WhatIfOnly]
Exit 0 = clean (nothing skipped as non-UTF-8), 1 = at least one file skipped.
#>
param(
  [string]$Root = '',
  [switch]$WhatIfOnly
)
$ErrorActionPreference = 'Stop'
if (-not $Root) {
    if ($env:MAILBOX_ROOT) { $Root = $env:MAILBOX_ROOT }
    elseif ($PSScriptRoot) { $Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }  # ops -> scripts -> root
    else { $Root = (Get-Location).Path }
}
$Root = (Get-Item -LiteralPath $Root).FullName

# Text-data extensions the mailbox system owns. Anything else (binaries,
# archives, images, js bundles) is out of scope by definition.
$exts = @('.md', '.log', '.ps1', '.psd1', '.progress', '.manifest', '.status', '.flag', '.json', '.txt')
# Trees that are not part of the live mailbox data: pristine backups, build
# inputs/outputs, web assets. Their bytes stay exactly as they were.
$exDirs = @('archive.bak', 'data', 'vendor', 'dist', 'node_modules', 'app', 'assets', 'dashboard')

$strict = New-Object System.Text.UTF8Encoding($false, $true)   # throwOnInvalidBytes
$bom = [byte[]](0xEF, 0xBB, 0xBF)
$scanned = 0; $already = 0; $done = 0; $empty = 0; $skippedBad = @()

$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $exts -contains $_.Extension.ToLower() })
foreach ($f in $files) {
    $rel = $f.FullName.Substring($Root.Length).TrimStart('\').Replace('\', '/')
    $excluded = $false
    foreach ($x in $exDirs) { if ($rel -like ($x + '/*')) { $excluded = $true; break } }
    if ($excluded) { continue }

    $scanned++
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $already++; continue }
    if ($bytes.Length -eq 0) { $empty++; continue }
    try { $null = $strict.GetString($bytes) } catch {
        $skippedBad += $rel
        continue
    }
    if (-not $WhatIfOnly) {
        # Archived files sit behind the close-time read-only lock: unlock,
        # write, re-lock - the lockdown state must survive the migration.
        $wasReadOnly = $f.IsReadOnly
        try {
            [System.IO.File]::WriteAllBytes($f.FullName, $bom + $bytes)
        } catch [System.UnauthorizedAccessException] {
            if (-not $wasReadOnly) { throw }
            $f.IsReadOnly = $false
            try { [System.IO.File]::WriteAllBytes($f.FullName, $bom + $bytes) } finally { $f.IsReadOnly = $true }
        }
    }
    $done++
}

Write-Host ('utf8-bom migration: scanned={0} already-bom={1} converted={2} empty={3} non-utf8={4}' -f $scanned, $already, $done, $empty, $skippedBad.Count)
foreach ($p in $skippedBad) { Write-Host ('  [SKIP not-utf8] ' + $p) }
if ($skippedBad.Count -gt 0) { exit 1 }
exit 0
