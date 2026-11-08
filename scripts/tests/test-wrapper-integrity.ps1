<#
test-wrapper-integrity.ps1 - static source hygiene for the scripts tree.

Catches the escape-corruption class that silently broke the root-level thin
shells in 2026-11: a file-writing layer ate C-style escapes while composing
the source, leaving real control bytes inside quoted path strings - the
testbot shell forwarded to a nonexistent path, exited 0 anyway, and the post
office logged STATUS ok for dispatches whose payload never ran.

Two checks, no sandbox, no mailbox touched:
  1. control bytes in any scripts ps1 file - TAB VT FF BEL BS NUL, plus CR
     not followed by LF (orphan CR). The byte fingerprint of that corruption.
  2. every literal Join-Path $PSScriptRoot target must resolve to an
     existing file/dir - a shell pointing at nothing fails here even if a
     future corruption uses an escape this scan does not know about.
Comment lines and block comments are skipped so prose examples do not
count as code.

Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\tests\test-wrapper-integrity.ps1 [-ScriptsDir <dir>]
Exit 0 = clean, 1 = at least one finding.
#>
param([string]$ScriptsDir = '')
$ErrorActionPreference = 'Stop'

if (-not $ScriptsDir) {
    $here = Split-Path $PSScriptRoot -Parent              # tests dir -> scripts
    if (Test-Path -LiteralPath (Join-Path $here 'core\common.ps1')) { $ScriptsDir = $here }
    else { $ScriptsDir = Split-Path $here -Parent }       # flat fallback
}

$bs = [string][char]92   # backslash, built at runtime - the source of this
$q  = [string][char]39   # file must never contain two adjacent backslashes

$files = @(Get-ChildItem -LiteralPath $ScriptsDir -Recurse -File -Filter '*.ps1' -ErrorAction SilentlyContinue)
$fail = 0

# ---- check 1: control bytes (TAB VT FF BEL BS NUL, orphan CR) ----
foreach ($f in $files) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $b = $bytes[$i]
        $orphanCr = ($b -eq 13 -and (($i + 1 -ge $bytes.Length) -or ($bytes[$i + 1] -ne 10)))
        if (($b -in 9, 11, 12, 7, 8, 0) -or $orphanCr) {
            Write-Host ('  [FAIL] control byte 0x{0:X2} in {1} @ offset {2}' -f $b, $f.FullName, $i)
            $fail++
        }
    }
}

# ---- check 2: literal Join-Path $PSScriptRoot targets resolve ----
# Line-based so prose in comments never counts as code; block comments skip.
$pat = 'Join-Path' + '\s+' + $bs + '$PSScriptRoot' + '\s+' + $q + '([^' + $q + ']+)' + $q
foreach ($f in $files) {
    $inBlock = $false
    foreach ($line in ([System.IO.File]::ReadAllText($f.FullName) -split '\r?\n')) {
        if ($inBlock) {
            if ($line.Contains('#>')) { $inBlock = $false }
            continue
        }
        $t = $line.TrimStart()
        if ($t.StartsWith('<#')) {
            if (-not $t.Contains('#>')) { $inBlock = $true }
            continue
        }
        if ($t.StartsWith('#')) { continue }
        foreach ($m in [regex]::Matches($line, $pat)) {
            $rel = $m.Groups[1].Value
            $target = Join-Path (Split-Path $f.FullName -Parent) $rel
            $exists = $false
            try { $exists = Test-Path -LiteralPath $target -ErrorAction Stop } catch { $exists = $false }
            if (-not $exists) {
                Write-Host ('  [FAIL] dangling Join-Path target in {0}: {1}' -f $f.FullName, $rel)
                $fail++
            }
        }
    }
}

Write-Host ('wrapper-integrity: {0} files scanned, {1} finding(s)' -f $files.Count, $fail)
if ($fail -gt 0) { exit 1 }
exit 0
