param(
  [switch]$Follow,
  [int]$EverySeconds = 2,
  [string]$Root = ''
)
$ErrorActionPreference = 'Stop'
if (-not $Root) {
    if ($env:MAILBOX_ROOT) { $Root = $env:MAILBOX_ROOT }
    else {
        # the script may sit in a subdir - walk up to the data root (a dir holding registry\)
        $d = $PSScriptRoot
        while ($d -and -not (Test-Path -LiteralPath (Join-Path $d 'registry'))) { $d = Split-Path $d -Parent }
        if ($d) { $Root = $d } elseif ($PSScriptRoot) { $Root = Split-Path $PSScriptRoot -Parent }
        else { $Root = (Get-Location).Path }
    }
}
. (Join-Path $PSScriptRoot 'common.ps1')

function Get-JournalFiles {
    $list = @()
    if (Test-Path -LiteralPath $script:DirLogs) {
        foreach ($f in (Get-ChildItem -LiteralPath $script:DirLogs -Recurse -File -ErrorAction SilentlyContinue)) {
            $list += $f.FullName
        }
    }
    return ,$list
}

function Get-AgentLabel {
    param([string]$Path)
    $leaf = Split-Path $Path -Leaf
    if ($leaf -eq 'system.log') { return 'system' }
    return (Split-Path (Split-Path $Path -Parent) -Leaf)
}

function Print-Snapshot {
    $entries = @()
    foreach ($f in (Get-JournalFiles)) {
        $agent = Get-AgentLabel -Path $f
        foreach ($line in ([System.IO.File]::ReadAllLines($f))) {
            if ($line -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) \| (\S+)\s*\| (.*)$') {
                $entries += [pscustomobject]@{ ts = $Matches[1]; agent = $agent; action = $Matches[2]; detail = $Matches[3] }
            }
        }
    }
    $entries = $entries | Sort-Object ts
    foreach ($e in $entries) {
        Write-Output ('{0} [{1,-8}] {2,-9} {3}' -f $e.ts, $e.agent, $e.action, $e.detail)
    }
}

if (-not $Follow) { Print-Snapshot; exit 0 }

# Follow mode: print history once, then tail like `tail -f`.
Print-Snapshot
$offsets = @{}
Write-Output (Get-AkText 'feed.following' '--- following (Ctrl+C to stop) ---')
while ($true) {
    foreach ($f in (Get-JournalFiles)) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $fi = Get-Item -LiteralPath $f
        if (-not $offsets.ContainsKey($f)) {
            $offsets[$f] = 0
            # v2.3.8: journals carry a UTF-8 BOM - start after it, or the 3
            # signature bytes desync the byte-offset bookkeeping below.
            if ($fi.Length -ge 3) {
                $head = New-Object byte[] 3
                $fs0 = [System.IO.File]::Open($f, 'Open', 'Read', 'ReadWrite')
                try { $null = $fs0.Read($head, 0, 3) } finally { $fs0.Close() }
                if ($head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF) { $offsets[$f] = 3 }
            }
        }
        if ($fi.Length -lt $offsets[$f]) { $offsets[$f] = 0 }   # truncated/rotated
        if ($fi.Length -gt $offsets[$f]) {
            $fs = [System.IO.File]::Open($f, 'Open', 'Read', 'ReadWrite')
            try {
                $fs.Seek($offsets[$f], 'Begin') | Out-Null
                $sr = New-Object System.IO.StreamReader($fs, $script:UTF8Bom)
                $rest = $sr.ReadToEnd()
                $idx = $rest.LastIndexOf("`n")
                if ($idx -ge 0) {
                    $chunk = $rest.Substring(0, $idx + 1)   # only complete lines
                    $offsets[$f] = $offsets[$f] + $script:UTF8Bom.GetByteCount($chunk)
                    foreach ($l in ($chunk.TrimEnd("`r", "`n") -split "`r?`n")) {
                        if ($l) { Write-Output $l }
                    }
                }
            } finally { $fs.Close() }
        }
    }
    Start-Sleep -Seconds $EverySeconds
}
